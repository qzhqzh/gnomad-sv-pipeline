# Run srtest on a single autosome, parallelizing across a fixed split size
workflow srtest_autosome {
  File vcf                      # Input VCF
  String splitfile              # Split read file
  File medianfile             # Median file
  File splitfile_idx            # Tabix index of split read file
  File svc_acct_key				# Service account key json
  String batch                  # Batch ID
  String algorithm              # Algorithm ID
  String chrom                  # Chromosome being processed
  Int split_size                # Number of lines in each srtest split

  # Compute the length of the suffix needed to accomodate all splits
  call compute_suffix_len {
    input:
      vcf=vcf,
      chrom=chrom,
      split_size=split_size
  }

  # Split the VCF into smaller chunks
  call split_vcf {
    input:
      vcf=vcf,
      batch=batch,
      algorithm=algorithm,
      chrom=chrom,
      split_size=split_size,
      suffix_len=compute_suffix_len.len
  }

  # Run srtest on each split
  scatter (split in split_vcf.split_vcfs) {
    # Add VCF header to split
    call reheader_split {
      input:
        vcf=vcf,
        split=split
    }

    # Run srtest
    call srtest {
      input:
        vcf=reheader_split.split_w_header,
        prefix=basename(split),
        splitfile=splitfile,
        medianfile=medianfile,
        splitfile_idx=splitfile_idx,
        svc_acct_key=svc_acct_key
    }
  }

  # Merge splits into single file
  call merge_splits {
    input:
      stats=srtest.stats,
      prefix="${batch}.${algorithm}.${chrom}"
  }

  output {
    File stats = merge_splits.merged_stats
  }
}

# Compute the length of the suffix necessary to accommodate all splits
task compute_suffix_len {
  File vcf
  String chrom
  Int split_size

  command <<<
    tabix -p vcf ${vcf};
    python3 <<CODE
    import numpy as np
    import pysam
    vcf = pysam.VariantFile('${vcf}')
    for i, record in enumerate(vcf.fetch('${chrom}')):
      continue
    n_records = i + 1
    n_splits = int(np.ceil(n_records / ${split_size}))
    suffix_len = max(int(np.ceil(np.log10(n_splits))), 1)
    print(suffix_len)
    CODE
  >>>

  output {
    Int len = read_int(stdout())
  }
  
  runtime {
  	preemptible: 3
    docker: "talkowski/sv-pipeline-remote-pysam"
  }
}

# Split VCF into fixed size chunks
task split_vcf {
  File vcf
  String batch
  String algorithm
  String chrom
  
  Int split_size
  Int suffix_len

  command {
    tabix -p vcf ${vcf};
    tabix ${vcf} ${chrom} | sort -R | split -a ${suffix_len} -d -l ${split_size} - ${batch}.${algorithm}.split.
  }

  output {
    Array[File] split_vcfs = glob("${batch}.${algorithm}.split.*")
  }
  
  runtime {
  	preemptible: 3
    docker: "talkowski/sv-pipeline-remote-pysam"
  }
}

# Restore VCF header to split files
task reheader_split {
  File vcf
  File split

  command {
    cat <(zcat ${vcf} | sed -n -e '/^#/p') ${split} | bgzip -c > ${basename(split)}.vcf.gz
  }

  output {
    File split_w_header = "${basename(split)}.vcf.gz"
  }
  
  runtime {
  	preemptible: 3
    docker: "talkowski/sv-pipeline-remote-pysam"
  }
}

# Run srtest
task srtest {
  File vcf
  String splitfile
  File medianfile
  File splitfile_idx
  File svc_acct_key
  String prefix
 
  command <<<
    url=$(gsutil signurl -d 24h ${svc_acct_key} ${splitfile} | sed '1d' | cut -f 4);
    echo $url;
    svtk vcf2bed --split-bnd --no-header ${vcf} test.bed
    awk -v OFS="\t" '{if ($2-250>0){print $1,$2-250,$2+250}else{print $1,0,$2+250}}' test.bed  >> region.bed
    awk -v OFS="\t" '{if ($3-250>0){print $1,$3-250,$3+250}else{print $1,0,$3+250}}' test.bed  >> region.bed
    sort -k1,1 -k2,2n region.bed > region.sorted.bed
    bedtools merge -i region.sorted.bed > region.merged.bed
    svtk remote_tabix "$url" ${splitfile_idx} -R region.merged.bed | bgzip -c > SR.txt.gz
    tabix -b 2 -e 2 SR.txt.gz
    svtk sr-test -w 50 --log --index SR.txt.gz.tbi --medianfile ${medianfile} ${vcf} SR.txt.gz ${prefix}.stats
  >>>
  
  output {
    File stats = "${prefix}.stats"
  }
  
  runtime {
  	disks: "local-disk 30 SSD"
  	preemptible: 3
    docker: "talkowski/sv-pipeline-remote-pysam"
  }
}

# Merge split srtest results into single file
task merge_splits {
  Array[File] stats
  String prefix

  command <<<
    while read split; do
      sed -e '1d' $split;
    done < ${write_tsv(stats)} | cat <(head -n1 ${stats[0]}) - > ${prefix}.stats
  >>>

  output {
    File merged_stats = "${prefix}.stats"
  }
  
  runtime {
  	preemptible: 3
    docker: "talkowski/sv-pipeline-remote-pysam"
  }
}