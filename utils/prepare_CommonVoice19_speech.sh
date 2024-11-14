#!/bin/bash

# Set bash to 'debug' mode, it will exit on :
# -e 'error', -u 'undefined variable', -o ... 'error in pipeline', -x 'print commands',
set -e
set -u
set -o pipefail

track=$1  # track1 or track2

output_dir="./commonvoice"
mkdir -p "${output_dir}"


langs=("de" "en" "es" "fr" "zh-CN")
# Please fill in URLs
# german, english, spanish, french, and chinese (china)
URLs=(
)

echo "=== Preparing CommonVoice data for ${track} ==="

mkdir -p tmp

if [ ! -f "${output_dir}/download_commonvoice.done" ]; then
    # check if language id and URL are in the same order
    for i in "${!langs[@]}"; do
        lang="${langs[$i]}"
        URL="${URLs[$i]}"
        
        filename="cv-corpus-19.0-2024-09-13-${lang}.tar.gz"

        if [[ "$URL" != *"$filename"* ]]; then
            echo "Link to commonvoice ${lang} may be wrong."
            echo "Note that language IDs and corresponding URLs must be in the same order."
            exit 1
        fi
    done

    # download the commonvoice data
    # all 5 files are downloaded in parallel
    org_dir=${PWD}
    cd $output_dir
    for i in "${!langs[@]}"; do
        echo "${langs[$i]} ${URLs[$i]}"
    done | xargs -n 2 -P 5 bash -c '
        lang="$1"
        URL="$2"
        echo "Downloading for $lang"
        wget "$URL" -O "cv19.0-${lang}.tar.gz"
    ' _
    cd $org_dir

    touch "${output_dir}/download_commonvoice.done"
fi

for lang in de en es fr zh-CN; do
    # untar the .tar.gz file
    output_dir_lang="${output_dir}/cv-corpus-19.0-2024-09-13/${lang}"
    if [ ! -d "${output_dir_lang}/clips" ]; then
        echo "[CommonVoice-${lang}] extracting audio files from ${output_dir}/cv19.0-${lang}.tar.gz"
        # Please do not change "-m 1000"
        python ./utils/tar_extractor.py -m 1000 \
            -i ${output_dir}/cv19.0-${lang}.tar.gz \
            -o ${output_dir} \
            --skip_existing --skip_errors
    fi

    for split in train dev; do
        echo "=== Preparing CommonVoice ${lang} ${split} data ==="

        if [ $split == "train" ]; then
            split_track="${split}_${track}"
            split_name=$split_track
        else
            split_track=$split
            split_name=validation
        fi

        BW_EST_FILE="tmp/commonvoice_19.0_${lang}_${split_track}.json"
        if [ ! -f ${BW_EST_FILE} ]; then
            echo "[CommonVoice-${lang}] resolve file paths"

            # .json.gz file containing bandwidth information for the 1st-track data is provided
            BW_EST_FILE_JSON_GZ="./datafiles/commonvoice/commonvoice_19.0_${lang}_${split_track}.json.gz"
            gunzip -c $BW_EST_FILE_JSON_GZ > $BW_EST_FILE

            # BW_EST_FILE_TMP only has file names
            # Resolve the path here
            python utils/resolve_file_path.py \
                --audio_dir ${output_dir_lang}/clips \
                --json_file ${BW_EST_FILE} \
                --outfile ${BW_EST_FILE} \
                --audio_format mp3
        else
            echo "Estimated bandwidth file already exists. Delete ${BW_EST_FILE} if you want to re-estimate."
        fi

        RESAMP_SCP_FILE=tmp/commonvoice_19.0_${lang}_resampled_${split_track}.scp
        if [ ! -f ${RESAMP_SCP_FILE} ]; then
            echo "[CommonVoice-${lang}] resampling to estimated audio bandwidth"
            OMP_NUM_THREADS=1 python utils/resample_to_estimated_bandwidth.py \
            --bandwidth_data ${BW_EST_FILE} \
            --out_scpfile ${RESAMP_SCP_FILE} \
            --outdir "${output_dir_lang}/resampled/${split_track}" \
            --max_files 5000 \
            --nj 8 \
            --chunksize 1000
        else
            echo "Resampled scp file already exists. Delete ${RESAMP_SCP_FILE} if you want to re-resample."
        fi

        echo "[CommonVoice-${lang}] preparing data files"
        python utils/get_commonvoice_subset_split.py \
            --scp_path ${RESAMP_SCP_FILE} \
            --tsv_path "${output_dir_lang}/${split}.tsv" \
            --outfile commonvoice_19.0_${lang}_resampled_${split_name}.scp

        # "other" split is included in training data in track2
        if [ $split_track == "train_track2" ]; then
            python utils/get_commonvoice_subset_split.py \
                --scp_path ${RESAMP_SCP_FILE} \
                --tsv_path "${output_dir_lang}/other.tsv" \
                --outfile commonvoice_19.0_${lang}_resampled_other.scp
            
            cat commonvoice_19.0_${lang}_resampled_other.scp >> commonvoice_19.0_${lang}_resampled_${split_name}.scp
            rm commonvoice_19.0_${lang}_resampled_other.scp
            sort -k1 commonvoice_19.0_${lang}_resampled_${split_name}.scp -o commonvoice_19.0_${lang}_resampled_${split_name}.scp
        fi
            
        awk 'FNR==NR {arr[$2]=$1; next} {print($1" cv11_"arr[$1".mp3"])}' \
            "${output_dir_lang}/${split}.tsv" \
            commonvoice_19.0_${lang}_resampled_${split_name}.scp \
            > commonvoice_19.0_${lang}_resampled_${split_name}.utt2spk

        python utils/get_commonvoice_transcript.py \
            --audio_scp commonvoice_19.0_${lang}_resampled_${split_name}.scp \
            --tsv_path "${output_dir_lang}/${split}.tsv" \
            --outfile commonvoice_19.0_${lang}_resampled_${split_name}.text

    done
done

#--------------------------------
# Output file (for each ${lang} and ${track}):
# -------------------------------
# commonvoice_19.0_${lang}_resampled_train_${track}.scp
#    - scp file containing samples (after resampling) for training
# commonvoice_19.0_${lang}_resampled_train_${track}.utt2spk
#    - speaker mapping for training samples
# commonvoice_19.0_${lang}_resampled_train_${track}.text
#    - transcript for training samples
# commonvoice_19.0_${lang}_resampled_validation.scp
#    - scp file containing samples (after resampling) for validation
# commonvoice_19.0_${lang}_resampled_validation.utt2spk
#    - speaker mapping for validation samples
# commonvoice_19.0_${lang}_resampled_validation.text
#    - transcript for validation samples
