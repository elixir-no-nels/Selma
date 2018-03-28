SAMPLES = ['Sample1']
INTERVALS = [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18]


rule all:
	input:
		"Outputs/ApplyVqsrSnp/SnpApplyVQSR.g.vcf.gz",
		"Outputs/ApplyVqsrIndel/IndelApplyVQSR.g.vcf.gz",

rule BwaMem:
	input:
		fasta = "/references/Homo_sapiens_assembly38.fasta",
		read1 = expand("fastq/{sample}.R1.fastq.gz", sample=SAMPLES),
		read2 = expand("fastq/{sample}.R2.fastq.gz", sample=SAMPLES),
	output:
		"Outputs/BwaMem/{sample}_mapped.bam",
	threads: 15
	singularity:
		"docker://oskarv/wdl"
	shell:
		"bwa mem -M -t 16 {input.fasta} {input.read1} {input.read2} | samtools view -Sb - > {output}"

rule FastqtoSam:
	input: 
		fasta = "/references/Homo_sapiens_assembly38.fasta",
		read1 = expand("fastq/{sample}.R1.fastq.gz", sample=SAMPLES),
		read2 = expand("fastq/{sample}.R2.fastq.gz", sample=SAMPLES),
	output:
		bam = "Outputs/FastqToSam/{samples}_unmapped.bam",
		tmp = "Outputs/FastqToSam/{samples}_tmp"
	singularity:
		"docker://oskarv/wdl"
	shell:
		"gatk --java-options -Djava.io.tempdir=`pwd`/tmp \
		FastqToSam \
		--FASTQ {input.read1} \
		--FASTQ2 {input.read2} \
		-O {output.bam} \
		--SAMPLE_NAME Sample1 \
		--READ_GROUP_NAME RGname \
		--LIBRARY_NAME Lib-1 \
		--PLATFORM ILLUMINA \
		--SORT_ORDER coordinate \
		--TMP_DIR {output.tmp}"

rule MergeBamAlignment:
	input:
		fasta = "/references/Homo_sapiens_assembly38.fasta",
		unmapped = "Outputs/FastqToSam/{sample}_unmapped.bam",
		mapped = "Outputs/BwaMem/{sample}_mapped.bam"
	output:
		bam = "Outputs/MergeBamAlignment/{sample}_merged.bam",
		tmp = "Outputs/MergeBamAlignment/{sample}_tmp"
	singularity:
		"docker://oskarv/wdl"
	shell:
		"gatk --java-options -Djava.io.tempdir=`pwd`/tmp \
		MergeBamAlignment \
		--VALIDATION_STRINGENCY SILENT \
		--EXPECTED_ORIENTATIONS FR \
		--ATTRIBUTES_TO_RETAIN X0 \
		--ALIGNED_BAM {input.mapped} \
		--UNMAPPED_BAM {input.unmapped} \
		-O {output.bam} \
		--REFERENCE_SEQUENCE {input.fasta} \
		--SORT_ORDER coordinate \
		--IS_BISULFITE_SEQUENCE false \
		--ALIGNED_READS_ONLY false \
		--CLIP_ADAPTERS false \
		--MAX_RECORDS_IN_RAM 200000 \
		--ADD_MATE_CIGAR true \
		--MAX_INSERTIONS_OR_DELETIONS -1 \
		--PRIMARY_ALIGNMENT_STRATEGY MostDistant \
		--PROGRAM_RECORD_ID 'bwamem' \
		--PROGRAM_GROUP_VERSION '0.7.12-r1039' \
		--PROGRAM_GROUP_COMMAND_LINE 'bwa mem -t 18 -R -M Input1 Input2 > output.sam' \
		--PROGRAM_GROUP_NAME 'bwamem' \
		--TMP_DIR {output.tmp}"

rule MarkDup:
	input:
		expand("Outputs/MergeBamAlignment/{sample}_merged.bam", sample=SAMPLES)
	output:
		"Outputs/MarkDuplicates/markedDuplicates.bam",
		"Outputs/MarkDuplicates/tmp",
	singularity:
		"docker://oskarv/wdl"
	run:
		INPUTS = " ".join(["--INPUT {}".format(x) for x in input])
		shell("gatk --java-options -Djava.io.tempdir=`pwd`/tmp \
		MarkDuplicates \
		{INPUTS} \
		-O Outputs/MarkDuplicates/markedDuplicates.bam \
		--VALIDATION_STRINGENCY LENIENT \
		--METRICS_FILE Outputs/MarkDuplicates/markedDuplicates.metrics \
		--MAX_FILE_HANDLES_FOR_READ_ENDS_MAP 200000 \
		--CREATE_INDEX true \
		--TMP_DIR Outputs/MarkDuplicates/tmp".format(INPUTS=INPUTS))

rule BaseRecalibrator:
	input:
		bam = "Outputs/MarkDuplicates/markedDuplicates.bam",
		fasta = "/references/Homo_sapiens_assembly38.fasta",
		dbsnp = "/references/dbsnp_146.hg38.vcf.gz",
		v1000g = "/references/1000G_phase1.snps.high_confidence.hg38.vcf.gz",
		mills = "/references/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz",
		intervals = "18-lists/{directory}_of_18/scattered.bed",
	output:
		grp = "Outputs/BaseRecalibrator/BQSR_{directory}.grp",
		tmp = "Outputs/BaseRecalibrator/{directory}_tmp"
	threads: 2
	singularity:
		"docker://oskarv/wdl"
	shell:
		"gatk --java-options -Djava.io.tempdir=`pwd`/tmp \
		BaseRecalibrator \
		--reference {input.fasta} \
		--input {input.bam} \
		-O {output} \
		--known-sites {input.dbsnp} \
		--known-sites {input.v1000g} \
		--known-sites {input.mills} \
		--intervals {input.intervals} \
		--TMP_DIR {output.tmp}"

rule GatherBQSR:
	input:
		expand("Outputs/BaseRecalibrator/BQSR_{directory}.grp", directory=INTERVALS),
	output:
		"Outputs/GatherBQSR/GatheredBQSR.grp",
	run:
		INPUTS = " ".join(["--input {}".format(x) for x in input])
		shell("gatk --java-options -Djava.io.tempdir=`pwd`/tmp \
		GatherBQSRReports \
		{INPUTS} \
		-O Outputs/GatherBQSR/GatheredBQSR.grp".format(INPUTS=INPUTS))

rule ApplyBQSR:
	input:
		bam = "Outputs/MarkDuplicates/markedDuplicates.bam",
		grp = "Outputs/GatherBQSR/GatheredBQSR.grp",
		fasta = "/references/Homo_sapiens_assembly38.fasta",
		intervals = "18-lists/{directory}_of_18/scattered.bed",
	output:
		bam = "Outputs/ApplyBQSR/{directory}_recalibrated.bam",
		tmp = "Outputs/ApplyBQSR/{directory}_tmp"
	threads: 2
	singularity:
		"docker://oskarv/wdl"
	shell:
		"gatk --java-options -Djava.io.tempdir=`pwd`/tmp \
		ApplyBQSR \
		--reference {input.fasta} \
		--input {input.bam} \
		-O {output.bam} \
		--create-output-bam-index true \
		-bqsr {input.grp} \
		--intervals {input.intervals} \
		--TMP_DIR {output.tmp}"

rule GatherBamFiles:
	input:
		expand("Outputs/ApplyBQSR/{directory}_recalibrated.bam", directory=INTERVALS),
	output:
		"Outputs/GatherBamFiles/GatheredBamFiles.bam",
	run:
		INPUTS = " ".join(["--INPUT {}".format(x) for x in input])
		shell("gatk --java-options -Djava.io.tempdir=`pwd`/tmp \
		GatherBamFiles \
		{INPUTS} \
		-O Outputs/GatherBamFiles/GatheredBamFiles.bam \
		--CREATE_INDEX true".format(INPUTS=INPUTS))

rule HaplotypeCaller:
	input:
		bam = "Outputs/GatherBamFiles/GatheredBamFiles.bam",
		fasta = "/references/Homo_sapiens_assembly38.fasta",
		intervals = "18-lists/{directory}_of_18/scattered.bed",
	output:
		vcf = "Outputs/HaplotypeCaller/{directory}_rawVariants.g.vcf.gz",
		tmp = "Outputs/HaplotypeCaller/{directory}_tmp"
	threads: 2
	singularity:
		"docker://oskarv/wdl"
	shell:
		"gatk --java-options '-Xmx8G -Djava.io.tempdir=`pwd`/tmp' \
		HaplotypeCaller \
		-R {input.fasta} \
		-O {output.vcf} \
		-I {input.bam} \
		-L {input.intervals} \
		-ERC GVCF \
		--TMP_DIR {output.tmp}"

rule GatherVCFs:
	input:
		expand("Outputs/HaplotypeCaller/{directory}_rawVariants.g.vcf.gz", directory=INTERVALS)
	output:
		"Outputs/GatherVCFs/GatheredVCFs.g.vcf",
	run:
		INPUTS = " ".join(["--INPUT {}".format(x) for x in input])
		shell("gatk --java-options -Djava.io.tempdir=`pwd`/tmp \
		MergeVcfs \
		{INPUTS} \
		-O Outputs/GatherVCFs/GatheredVCFs.g.vcf \
		--CREATE_INDEX false".format(INPUTS=INPUTS))

rule GenotypeGVCFs:
	input:
		vcf = "Outputs/GatherVCFs/GatheredVCFs.g.vcf",
		fasta = "/references/Homo_sapiens_assembly38.fasta",
	output:
		vcf = "Outputs/GenotypeGVCFs/genotypes.g.vcf.gz",
		tmp = "Outputs/GenotypeGVCFs/tmp"
	singularity:
		"docker://oskarv/wdl"
	shell:
		"gatk --java-options -Djava.io.tempdir=`pwd`/tmp \
		GenotypeGVCFs \
		-R {input.fasta} \
		-O {output.vcf} \
		-V {input.vcf} \
		--TMP_DIR {output.tmp}"

rule VariantRecalibratorSNP:
	input:
		vcf = "Outputs/GenotypeGVCFs/genotypes.g.vcf.gz",
		fasta = "/references/Homo_sapiens_assembly38.fasta",
		dbsnp = "/references/dbsnp_146.hg38.vcf.gz",
		v1000g = "/references/1000G_phase1.snps.high_confidence.hg38.vcf.gz",
		omni = "/references/1000G_omni2.5.hg38.vcf.gz",
		hapmap = "/references/hapmap_3.3.hg38.vcf.gz"
	output:
		recal = "Outputs/VariantRecalibratorSNP/SnpVQSR.recal",
		tranches = "Outputs/VariantRecalibratorSNP/SnpVQSR.tranches",
		tmp = "Outputs/VariantRecalibratorSNP/tmp"
	singularity:
		"docker://oskarv/wdl"
	shell:
		"gatk --java-options -Djava.io.tempdir=`pwd`/tmp \
		VariantRecalibrator \
		-R {input.fasta} \
		-V {input.vcf} \
		--mode SNP \
		--resource v1000G,known=false,training=true,truth=false,prior=10.0:{input.v1000g} \
		--resource omni,known=false,training=true,truth=true,prior=12.0:{input.omni} \
		--resource dbsnp,known=true,training=false,truth=false,prior=2.0:{input.dbsnp} \
		--resource hapmap,known=false,training=true,truth=true,prior=15.0:{input.hapmap} \
		-an QD -an MQ -an DP -an MQRankSum -an ReadPosRankSum -an FS -an SOR \
		-tranche 100.0 -tranche 99.95 -tranche 99.9 -tranche 99.8 -tranche 99.6 \
		-tranche 99.5 -tranche 99.4 -tranche 99.3 -tranche 99.0 -tranche 98.0 \
		-tranche 97.0 -tranche 90.0 \
		--tranches-file {output.tranches} \
		--output {output.recal} \
		--TMP_DIR {output.tmp}"

rule VariantRecalibratorINDEL:
	input:
		vcf = "Outputs/GenotypeGVCFs/genotypes.g.vcf.gz",
		fasta = "/references/Homo_sapiens_assembly38.fasta",
		dbsnp = "/references/dbsnp_146.hg38.vcf.gz",
		mills = "/references/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz",
	output:
		recal = "Outputs/VariantRecalibratorINDEL/IndelVQSR.recal",
		tranches = "Outputs/VariantRecalibratorINDEL/IndelVQSR.tranches",
		tmp = "Outputs/VariantRecalibratorINDEL/tmp"
	singularity:
		"docker://oskarv/wdl"
	shell:
		"gatk --java-options -Djava.io.tempdir=`pwd`/tmp \
		VariantRecalibrator \
		-R {input.fasta} \
		-V {input.vcf} \
		--mode INDEL \
		--resource mills,known=false,training=true,truth=true,prior=12.0:{input.mills} \
		--resource dbsnp,known=true,training=false,truth=false,prior=2.0:{input.dbsnp} \
		-an QD -an DP -an FS -an SOR -an ReadPosRankSum -an MQRankSum -tranche 100.0 \
		-tranche 99.95 -tranche 99.9 -tranche 99.5 -tranche 99.0 -tranche 97.0 -tranche 96.0 \
		-tranche 95.0 -tranche 94.0 -tranche 93.5 -tranche 93.0 -tranche 92.0 -tranche 91.0 \
		-tranche 90.0 \
		--tranches-file {output.tranches} \
		--output {output.recal} \
		--TMP_DIR {output.tmp}"

rule ApplyVqsrSnp:
	input:
		vcf = "Outputs/GenotypeGVCFs/genotypes.g.vcf.gz",
		fasta = "/references/Homo_sapiens_assembly38.fasta",
		recal = "Outputs/VariantRecalibratorSNP/SnpVQSR.recal",
		tranches = "Outputs/VariantRecalibratorSNP/SnpVQSR.tranches"
	output:
		vcf = "Outputs/ApplyVqsrSnp/SnpApplyVQSR.g.vcf.gz",
		tmp = "Outputs/ApplyVqsrSnp/tmp",
	singularity:
		"docker://oskarv/wdl"
	shell:
		"gatk --java-options -Djava.io.tempdir=`pwd`/tmp \
		ApplyVQSR \
		-V {input.vcf} \
		-R {input.fasta} \
		--mode SNP \
		-ts-filter-level 99.6 \
		-tranches-file {input.tranches} \
		-recal-file {input.recal} \
		-O {output} \
		--TMP_DIR {output.tmp}"

rule ApplyVqsrIndel:
	input:
		vcf = "Outputs/GenotypeGVCFs/genotypes.g.vcf.gz",
		fasta = "/references/Homo_sapiens_assembly38.fasta",
		recal = "Outputs/VariantRecalibratorINDEL/IndelVQSR.recal",
		tranches = "Outputs/VariantRecalibratorINDEL/IndelVQSR.tranches"
	output:
		vcf = "Outputs/ApplyVqsrIndel/IndelApplyVQSR.g.vcf.gz",
		tmp = "Outputs/ApplyVqsrIndel/tmp",
	singularity:
		"docker://oskarv/wdl"
	shell:
		"gatk --java-options -Djava.io.tempdir=`pwd`/tmp \
		ApplyVQSR \
		-V {input.vcf} \
		-R {input.fasta} \
		--mode INDEL \
		-ts-filter-level 95.0 \
		-tranches-file {input.tranches} \
		-recal-file {input.recal} \
		-O {output} \
		--TMP_DIR {output.tmp}"
