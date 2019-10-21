### Snakemake plan for the whole workflow

# Define input path for fastq files
input_path_fq = "../data/X201SC19060242-Z01-F001/raw_data/"
input_base_fq, = glob_wildcards("../data/X201SC19060242-Z01-F001/raw_data/{base}.fq.gz")

# Download reference mycoplasma genome
rule download_mycoplasma:
  output:  '../data/mycoplasma/GCF_003663725.1_ASM366372v1_rna_from_genomic.fna.gz'
  shell: 'wget -r -np -k -N -nd -P ../data/mycoplasma/ ftp://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/003/663/725/GCF_003663725.1_ASM366372v1/'


# Test sequences with fastqc
fq_outpath = "results/fastqc/"

rule fastqc:
  input:
    fq = expand("{path}{base}.fq.gz", base = input_base_fq, path = input_path_fq)
  output:
    expand("{path}{base}_fastqc.html", base = input_base_fq, path = fq_outpath)
  shell:
    "nice --adjustment=+10 fastqc {input.fq} -o={fq_outpath} -t=128"

# Trim 20 bp from 5' end to remove primer adapter bias

# Map to reference mycoplasma genome

# Quantify mycoplasma expression
