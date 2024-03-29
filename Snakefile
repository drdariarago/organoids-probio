### Snakemake plan for the whole workflow

# Define input path for fastq files
input_path_fq = "data/X201SC19060242-Z01-F001/raw_data/"
input_base_fq, = glob_wildcards("data/X201SC19060242-Z01-F001/raw_data/{base}.fq.gz")
sample_id = ["A_" + str(i) for i in range(1,73)]

# Define standard bowtie2 reference suffixes
bowtie_suffixes = (
  *[".{id}.bt2".format(id = i) for i in range(1,5)],
  *[".rev.{id}.bt2".format(id = i) for i in range(1,3)]
)

# Define contrast suffix for input/output files
contrasts = ("2D_vs_3D","2D_vs_LGG")

# rule all to generate all output files at once
rule all:
  params:
    in_base = input_base_fq,
    in_path = input_path_fq
  input:
    fastq_files = expand("{path}{base}.fq.gz", base = input_base_fq, path = input_path_fq),
    fastqc_reports = expand("results/fastqc/{base}_fastqc.html", base = input_base_fq),
    mycoplasma_report = "results/reports/mycoplasma_report.html",
    expression_report = "results/reports/expression_report.html",
    DESeq = expand("results/deseq/DE_{contrasts}.Rdata", contrasts = contrasts),
    GO_results = expand("results/GOexpress/GO_results_{contrasts}.Rdata", contrasts = contrasts)

# Download reference mycoplasma genome
rule download_mycoplasma:
  output:
    'data/mycoplasma/GCF_003663725.1_ASM366372v1_genomic.fna.gz'
  log:
    "logs/download_mycoplasma.txt"
  shell:
    'wget -r -np -k -N -nd -P data/mycoplasma/ ftp://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/003/663/725/GCF_003663725.1_ASM366372v1/ 2> {log}'

# Test sequences with fastqc
rule fastqc:
  input:
    fq = expand("{path}{base}.fq.gz", base = input_base_fq, path = input_path_fq)
  output:
    expand("results/fastqc/{base}_fastqc.html", base = input_base_fq)
  log:
    "logs/fastqc"
  threads: 6
  shell:
    "nice -n 10 fastqc {input.fq} -threads {threads} -o=results/fastqc/ 2> {log}"

# Trim 20 bp from 5' end to remove primer adapter bias
rule trim_reads:
  params:
    in_base = input_base_fq,
    in_path = input_path_fq
  input:
    expand("{path}{base}.fq.gz", base = input_base_fq, path = input_path_fq)
  output:
    expand("results/trim_reads/{base}.fq", base = input_base_fq)
  shell:
    '''
    for file in {params.in_base}
    do
    nice --adjustment=+10 seqtk trimfq -b 20 {params.in_path}$file.fq.gz > results/trim_reads/$file.fq
    done
    '''

# Download reference genomes for human and mouse
rule reference_index:
  output:
    expand("data/fastq_screen_references/FastQ_Screen_Genomes/Human/Homo_sapiens.GRCh38{suffix}", suffix = bowtie_suffixes)
  shell:
    "fastq_screen --get_genomes --outdir data/fastq_screen_references"

# Map to mycoplasma transcriptome
rule mycoplasma_reference:
  input:
    'data/mycoplasma/GCF_003663725.1_ASM366372v1_genomic.fna.gz'
  output:
    mycoplasma_genome = temp("results/mycoplasma_reference/mycoplasma_genome.fa"),
    mycoplasma_reference = expand("results/mycoplasma_reference/mycoplasma_reference{suffix}", suffix = bowtie_suffixes),
  shell:
    '''
    gzip -cd {input} > {output.mycoplasma_genome}  &&
    bowtie2-build --seed 42 {output.mycoplasma_genome} mycoplasma_reference &&
    mv mycoplasma_reference* results/mycoplasma_reference
    '''

# Use fastq Screen for mycoplasma detection
rule fastq_screen:
  input:
    shared_reference_genomes = expand("data/fastq_screen_references/FastQ_Screen_Genomes/Human/Homo_sapiens.GRCh38{suffix}", suffix = bowtie_suffixes),
    fastq = expand("results/trim_reads/{basename}.fq", basename = input_base_fq),
    mycoplasma_reference = expand("results/mycoplasma_reference/mycoplasma_reference{suffix}", suffix = bowtie_suffixes),
  output:
    fastq_txt = expand("results/fastq_screen/{basename}_screen.txt", basename = input_base_fq),
    fastq_html = expand("results/fastq_screen/{basename}_screen.html", basename = input_base_fq),
  threads: 16
  shell:
    '''
    nice -n 10 \
    fastq_screen \
        --subset 0 --outdir results/fastq_screen --conf scripts/fastq_screen.conf --threads {threads} {input.fastq}
    '''

# Create report on mycoplasma contmination
rule mycoplasma_report:
  input:
    fastq_txt = expand("results/fastq_screen/{basename}_screen.txt", basename = input_base_fq),
    script = "scripts/mycoplasma_report.Rmd"
  output:
    "results/reports/mycoplasma_report.html"
  shell:
    '''
    Rscript -e "rmarkdown::render('{input.script}')"
    mv scripts/mycoplasma_report.html results/reports/mycoplasma_report.html
    '''

# Download human reference transcriptome from Gencode v32
rule download_human:
  output:
    transcriptome = 'data/Human/gencode.v32.transcripts.fa.gz',
    genome = 'data/Human/gencode.v32.annotation.gtf.gz'
  log:
    "logs/download_human.txt"
  shell:
    '''
    curl -o {output.transcriptome} ftp://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_32/gencode.v32.transcripts.fa.gz 2> {log}
    curl -o {output.genome} ftp://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_32/GRCh38.primary_assembly.genome.fa.gz
    '''

# Index human genome for salmon quantification
rule salmon_index:
  input:
      transcriptome = "data/Human/gencode.v32.transcripts.fa.gz",
      genome = "data/Human/gencode.v32.annotation.gtf.gz"

  output:
      decoys = "results/salmon/human_transcriptome_index/decoys.txt",
      gentrome = "results/salmon/human_transcriptome_index/gentrome.fa",
      index = directory("results/salmon/human_transcriptome_index/ref_idexing"),

  threads: 30

  params:
      kmer = 31

  shell:
      '''
      # Crate decoy file
      echo "Creating Decoy File"
      grep "^>" <(zcat {input.genome}) | cut -d " " -f 1 > {output.decoys} &&
      sed -i -e 's/>//g' {output.decoys} &&

      # Concatenate genome and transcriptome
      echo "Concatenating genome and transcriptome"
      zcat {input.transcriptome} {input.genome} > {output.gentrome} &&

      # Create index
      echo "Creating index"
      salmon index \
                -t {output.gentrome} \
                -i {output.index} \
                -d {output.decoys} \
                -p {threads} \
                -k {params.kmer} \
                --gencode
      '''

# Quantify read counts via Samon
rule salmon_quant:
  input:
    index = "results/salmon/human_transcriptome_index/ref_idexing",
    reads_1 = [expand("results/trim_reads/{id}_1.fq", id = id) for id in sample_id],
    reads_2 = [expand("results/trim_reads/{id}_2.fq", id = id) for id in sample_id]

  output:
    outdir = directory([expand("results/salmon/salmon_quant/{id}", id = id) for id in sample_id])

  params:
    libtype = "ISR",
    numBootstraps = 30,
    minScoreFraction = 0.8,
    jobs = lambda wildcards, threads: threads//5,
    salmonThreads = 5,
    outdir = [expand("results/salmon/salmon_quant/{id}", id = id) for id in sample_id]

  threads: 30

  shell:
    '''

    ionice -c2 -n7 \
    parallel --link --jobs {params.jobs} \
    salmon quant \
            -i {input.index} \
            -l {params.libtype} \
            -1 {{1}} \
            -2 {{2}} \
            -o {{3}} \
            --validateMappings \
            --minScoreFraction {params.minScoreFraction} \
            --numBootstraps {params.numBootstraps}\
            --gcBias \
            --seqBias \
            --writeUnmappedNames \
            --threads {params.salmonThreads} \
    ::: {input.reads_1} \
    ::: {input.reads_2} \
    ::: {output.outdir}

    '''

# Convert sample metadata to tidy csv table
rule metadata_import:
  input:
    patient_data = 'data/experiment_metadata/Clinical_characteristics_Herlevstudy.xlsx',
    sample_treatment = 'data/experiment_metadata/In vitro trial RNA sample overwiev.xlsx'
  output:
    'results/metadata_import/experiment_metadata.csv'
  script:
    'scripts/metadata_import.R'

# Import reads and feature metadata into R via tximeta
rule tximeta:
  input:
    salmon_dirs = [expand("results/salmon/salmon_quant/{id}", id = id) for id in sample_id],
    sample_metadata = "results/metadata_import/experiment_metadata.csv"
  output:
   'results/tximeta/gene_data.Rdata',
   'results/tximeta/variance_stabilized_counts.csv'
  script:
    'scripts/tximeta.R'

# Create knitr expression report from main experiment (includes PCA, heatmap and other QC/exploration steps)
rule expression_report:
  input:
    gene_data = "results/tximeta/gene_data.Rdata",
    script = "scripts/expression_report.Rmd"
  output:
    "results/reports/expression_report.html"
  shell:
    '''
    Rscript -e "rmarkdown::render('{input.script}')"
    mv scripts/expression_report.html {output}
    '''

# Analyze samples via DESeq2
rule deseq:
  input:
    "results/tximeta/gene_data.Rdata"
  output:
    controls = "results/deseq/DE_2D_vs_3D.Rdata",
    probiotics = "results/deseq/DE_2D_vs_LGG.Rdata"
  threads: 5
  script:
    'scripts/deseq.R'

# Calculate GO enrichment via GOexpress
rule GOexpress:
  input:
    "results/deseq/DE_{contrast}.Rdata"
  output:
    expression_set = "results/GOexpress/expression_set_{contrast}.Rdata",
    GO_results = "results/GOexpress/GO_results_{contrast}.Rdata",
    q_value_table = "results/GOexpress/GO_qvalues_{contrast}.csv"
  params:
    ntree = 1E4,
    min_genes_per_GO = 10,
    p_value_permutations = 1E3
  threads: 1
  script:
    "scripts/GO_enrichment.R"
