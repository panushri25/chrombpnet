#!/bin/bash
##TODO flank_size and ref_fasta files in scripts 

cell_line=H1
data_type="ATAC"

date=$(date +'%m.%d.%Y')
#setting=tobias_$data_type"_"$date
cur_file_name="h1_atac_script.sh"
setting=tobias_ATAC_07.26.2021

### SIGNAL INPUT

uncorrected_bw=$PWD/$cell_line/data/shifted_4_4.sorted.bam.bpnet.unstranded.bw
bias_bw=$PWD/tobias_scripts/$cell_line/$cell_line.atac.filt.merged_expected.bw

overlap_peak=/oak/stanford/groups/akundaje/projects/atlas/atac/caper_out/58fb3f13-be45-45de-8a39-d0bfbeaf86c5/call-reproducibility_overlap/glob-1b1244d5baf1a7d98d4b7b76d79e43bf/overlap.optimal_peak.narrowPeak.gz
idr_peak=/oak/stanford/groups/akundaje/projects/atlas/atac/caper_out/58fb3f13-be45-45de-8a39-d0bfbeaf86c5/call-reproducibility_idr/glob-1b1244d5baf1a7d98d4b7b76d79e43bf/idr.optimal_peak.narrowPeak.gz

blacklist_region=$PWD/data/all_three_blacklists.bed
chrom_sizes=$PWD/data/hg38.chrom.sizes
ref_fasta=/mnt/data/GRCh38_no_alt_analysis_set_GCA_000001405.15.fasta

main_dir=$PWD/tobias_scripts/$cell_line
data_dir=$PWD/tobias_scripts/$cell_line
output_dir=$PWD/tobias_scripts/$cell_line/$setting

### MODEL PARAMS

gpu=3
filters=500 
n_dil_layers=8
seed=1234 
model_name=model 
flank_size=1057

## CREATE DIRS

if [[ -d $main_dir ]] ; then
    echo "main director already exists"
else
    mkdir $main_dir
fi

if [[ -d $output_dir ]] ; then
    echo "output director already exists"
else
    mkdir $output_dir
fi


### CREATE FOLDER TILEDB AND RUN TILEDB

if [[ -d $data_dir/tiledb ]] ; then
    echo "skipping tiledb"
else
    mkdir $data_dir/tiledb
    echo -e "dataset\tidr_peak\toverlap_peak\tambig_peak\tcount_bigwig_unstranded_5p\tcontrol_count_bigwig_unstranded_5p\n"$cell_line"\t"$idr_peak"\t"$overlap_peak"\t"$blacklist_region"\t"$uncorrected_bw"\t"$bias_bw > $data_dir/tiledb/inputs.tsv
    echo -e "overlap_peak\tbed_summit_from_last_col\nidr_peak\tbed_summit_from_last_col\nambig_peak\tbed_no_summit\ncount_bigwig_unstranded_5p\tbigwig\ncontrol_count_bigwig_unstranded_5p\tbigwig" > $data_dir/tiledb/attribs.txt
    ./main_scripts/db_ingest.sh  $data_dir/tiledb/inputs.tsv $data_dir/tiledb/db $chrom_sizes $data_dir/tiledb/attribs.txt
    cp $PWD/tobias_scripts/$cur_file_name $data_dir/tiledb
fi



### STEP 3 - FIT BIAS AND SIGNAL MODEL

if [[ -d $output_dir/model ]] ; then
    echo "skipping model training"
else
    mkdir $output_dir/model
    bash $PWD/main_scripts/get_loss_weights.sh $data_dir/tiledb/db "chr10" "overlap_peak" "count_bigwig_unstranded_5p" $cell_line $flank_size $output_dir/model/counts_loss_weight.txt
    counts_loss_weight=`cat $output_dir/model/counts_loss_weight.txt`
    echo -e "counts_loss_weight\t"$counts_loss_weight"\nprofile_loss_weight\t1\nfilters\t"$filters"\nn_dil_layers\t"$n_dil_layers > $output_dir/model/params.txt
    params=$output_dir/model/params.txt
    for fold in 0
    do
        ./tobias_scripts/main_scripts/model/train.sh $fold $gpu $model_name $seed $output_dir/model $params  $data_dir/tiledb/db $cell_line $PWD/tobias_scripts/main_scripts/model/profile_bpnet_dnase_with_bias.py
        ./tobias_scripts/main_scripts/model/predict.sh $fold $gpu $model_name $seed  $output_dir/model  $data_dir/tiledb/db $cell_line $chrom_sizes
        ./tobias_scripts/main_scripts/model/score.sh $output_dir/model $model_name $fold $cell_line $seed
    done
    cp $PWD/tobias_scripts/$cur_file_name $output_dir/model
fi




## UNPLUG MODEL

if [[ -d $output_dir/model/unplug ]] ; then
    echo "skipping unplugging"
else
    mkdir $output_dir/model/unplug
    counts_loss_weight=`cat $output_dir/model/counts_loss_weight.txt`
    unplug_bias_json=$output_dir/model/model.0.arch
    unplug_bias_weights=$output_dir/model/model.0.weights
    echo -e "json_string\t"$unplug_bias_json"\nweights\t"$unplug_bias_weights"\ncounts_loss_weight\t"$counts_loss_weight"\nprofile_loss_weight\t1\nfilters\t"$filters"\nn_dil_layers\t"$n_dil_layers > $output_dir/model/unplug/params.txt

    params=$output_dir/model/unplug/params.txt

    for fold in 0
    do
        CUDA_VISIBLE_DEVICES=$gpu python ./main_scripts/unplug/get_model_with_bias_unplugged.py --model_params $params --outf $output_dir/model/unplug/$model_name.$fold.hdf5
        ./main_scripts/unplug/predict.sh $fold $gpu $model_name $seed $output_dir/model/unplug $data_dir/tiledb/db $cell_line $chrom_sizes
        ./main_scripts/unplug/score.sh $output_dir/model/unplug $model_name $fold $cell_line $seed
    done
    cp $PWD/$cur_file_name $output_dir/model/unplug
fi




### GET INTERPRETATIONS



if [[ -d $output_dir/model/unplug/deepshap ]] ; then
    echo "skipping interpretations"
else
    mkdir $output_dir/model/unplug/deepshap
    bed_file=$PWD/$cell_line/data/$cell_line"_idr_split"

    for fold in 0
    do
        ./main_scripts/interpret/interpret.sh $output_dir/model/unplug/$model_name.$fold.hdf5 $bed_file xaa $data_dir/tiledb/db $chrom_sizes $output_dir/model/unplug/deepshap $cell_line $gpu $fold
        ./main_scripts/interpret/interpret.sh $output_dir/model/unplug/$model_name.$fold.hdf5 $bed_file xab $data_dir/tiledb/db $chrom_sizes $output_dir/model/unplug/deepshap $cell_line $gpu $fold
        ./main_scripts/interpret/interpret.sh $output_dir/model/unplug/$model_name.$fold.hdf5 $bed_file xac $data_dir/tiledb/db $chrom_sizes $output_dir/model/unplug/deepshap $cell_line $gpu $fold
    done

    python $PWD/main_scripts/interpret/combine_shap_pickle.py --source $output_dir/model/unplug/deepshap --target $output_dir/model/unplug/deepshap --type 20k
    cp $PWD/tobias_scripts/$cur_file_name $output_dir/model/unplug/deepshap

fi

modisco_sig_dir=/oak/stanford/groups/akundaje/projects/chrombpnet_paper/importance_scores/SIGNAL/

if [[ -d $modisco_sig_dir/$cell_line ]] ; then
    echo "modisco dir already exists"
else
    mkdir $modisco_sig_dir/$cell_line
fi

if [[ -d $modisco_sig_dir/$cell_line/$setting/ ]] ; then
    echo "modisco dir already exists"
else
    mkdir $modisco_sig_dir/$cell_line/$setting/
    modisco_dir_final=$modisco_sig_dir/$cell_line/$setting/
    cp  tobias_scripts/$cell_line/$setting/model/unplug/deepshap/20K.fold0.deepSHAP $modisco_dir_final
fi

### RUN MODISCO


