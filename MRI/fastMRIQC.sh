#!/bin/bash

# Function to display usage instructions
SHOW_HELP() {
cat << EOF

Usage: $0 -p <SubjectID> [-b <BIDS_ROOT>] [-s <SESSION>] [-o <QC_ROOT>] [-h]

Arguments:
  -p <SubjectID>  : Mandatory. Specify the subject ID to be processed.
  -b <BIDS_ROOT>  : Optional. Specify the root directory of the BIDS dataset. Defaults to the current working directory.
  -s <SESSION>    : Optional. Specify a particular session to process. If not provided, all sessions for the subject will be processed.
  -o <QC_ROOT>    : Optional. Specify the output directory for QC reports. Defaults to a 'qc' directory adjacent to the BIDS root.
  -h, --help      : Display this help message and exit.


# ------------------------------------------------------------------------

This script automates few basic quality control checks of MRI data.
It reviews the content in anatomical (anat), diffusion-weighted imaging (dwi), and functional (func) folders of a BIDS formatted MRI dataset, 
generating a QC report in HTML format (typically all under 2-3 minutes).

The goal is to complete this quick version of QC on the same day as MRI acquisition, allowing for timely review and decision-making.

# ------------------------------------------------------------------------

Requirements:
  - BIDS-formatted data: The MRI data must be organized in BIDS format. Use tools like "dcm2bids" to convert DICOM to BIDS.
  - AFNI: Required for image processing and QC analysis. Install from the AFNI website "https://afni.nimh.nih.gov/pub/dist/doc/htmldoc/background_install/main_toc.html".
  - tedana: Needed for multi-echo fMRI data processing. Install via pip ("pip install tedana").
  - jq: For processing JSON metadata. Install via package manager (e.g., "sudo apt-get install jq").
  - bc: Command-line calculator for arithmetic operations. Install via package manager (e.g., "sudo apt-get install bc").

# ------------------------------------------------------------------------

Modality-Specific QC Overview:

  Anatomical (anat):
    - Generates QC montages for all anatomical scans within the anat folder.

  Diffusion-Weighted Imaging (dwi):
    - Generates 4D QC montages, displaying one slice per DWI volume with separate scalings for each volume.
    - Sagittal view montages are useful for inspecting volumes corrupted by motion (e.g., venetian blind effect).
    - Axial views help assess the extent of EPI geometric distortions.
    - Automated reports are generated for motion corruption using 3dZipperZapper.
    - Calculates between-TR motion and generates corresponding motion plots.
    - Summarizes phase encoding information and slice-drop/motion corruption data.

  Functional (func):
    - Generates TSNR (Temporal Signal-to-Noise Ratio) and temporal standard deviation maps.
    - Calculates between-TR motion and generates motion plots and carpet grayplot images.
    - Calculates AFNI's outlier and quality indices.
    - Computes Ghost to Signal Ratio (GSR) in the x and y directions to quantify ghosting artifacts.
    - Detects multi-echo functional data (>= 3 echoes) and, if present, uses tedana to generate T2* and S0 maps, along with RMSE (Root Mean Square Error) maps.

Summary:
  - Collects and summarizes key MRI acquisition parameters (e.g., matrix size, slice count, number of dynamics, TR, orientation) into an HTML table.
  - Provides a detailed, session-specific QC report in HTML format, offering a visual and quantitative assessment of the MRI data quality.

# ------------------------------------------------------------------------

Decision Buttons in QC Report:

  - After processing, the script generates a QC report in HTML format, which includes buttons for manual review of each file.
  - The buttons allow the user to categorize each file as:
      1. Reject/Problem 
      2. Borderline/Warning 
      3. OK
  - Users can also provide comments for each file.
  - A "Submit QC and Save Report" button at the end of the report allows saving the final decision for all files, including their QC status and comments, in a text file.

# ------------------------------------------------------------------------
# Fast MRI Quality Control (QC) Script v0.5
# Written by Bharath Holla (NIMHANS, Bengaluru)
# ------------------------------------------------------------------------


EOF
}

# Default values for optional arguments
BIDS_ROOT=$(pwd)
SESSION=""
QC_ROOT=""

# Parse command-line arguments
while getopts ":p:b:s:o:h" opt; do
    case $opt in
        p)
            SUBJECT_ID=$OPTARG
            ;;
        b)
            BIDS_ROOT=$(realpath $OPTARG)
            ;;
        s)
            SESSION=$OPTARG
            ;;
        o)
            QC_ROOT=$OPTARG
            ;;
        h)
            SHOW_HELP
            exit 0
            ;;
        \?)
            SHOW_HELP
            exit 1
            ;;
    esac
done

# Check if the required SUBJECT_ID is provided
if [ -z "$SUBJECT_ID" ]; then
    echo "Error: Subject ID (-p) is required."
    SHOW_HELP
    exit 1
fi

# Set default QC_ROOT if not provided
if [ -z "$QC_ROOT" ]; then
    QC_ROOT="${BIDS_ROOT}/../qc"
fi


# Start timer for QC report generation
start_time=$(date +%s)

mkdir -p "${QC_ROOT}"
QC_ROOT=$(realpath ${QC_ROOT})

# Check if the subject directory exists
SUBJECT_PATH="${BIDS_ROOT}/sub-${SUBJECT_ID}"
if [ ! -d "$SUBJECT_PATH" ]; then
    echo "Error: Subject directory for sub-${SUBJECT_ID} not found in ${BIDS_ROOT}."
    exit 1
fi

# If a session is specified, only process that session; otherwise, process all sessions
if [ -n "$SESSION" ]; then
    SESSIONS="ses-$SESSION"
else
    SESSIONS=$(ls ${SUBJECT_PATH} | grep ses-)
fi

for SESSION in ${SESSIONS[@]}; do
    SESSION_PATH="${SUBJECT_PATH}/${SESSION}"
    QC_SESSION_PATH="${QC_ROOT}/sub-${SUBJECT_ID}/${SESSION}"
    HTML_REPORT_PATH="${QC_ROOT}/QC_Report_sub-${SUBJECT_ID}_${SESSION}.html"

    # Check if the QC report already exists
    if [ -f "$HTML_REPORT_PATH" ]; then
        echo "QC report for sub-${SUBJECT_ID} ${SESSION} already exists. Skipping..."
        exit 1
    fi

    mkdir -p "${QC_SESSION_PATH}"

    # Start HTML report
    echo "<html><head><title>MRI QC Report for ${SUBJECT_ID} ${SESSION}</title></head><body>" > ${HTML_REPORT_PATH}
    echo "<style>img { max-width: 100%; height: auto; }</style>" >> ${HTML_REPORT_PATH}
    echo "<h1>MRI QC Report</h1>" >> ${HTML_REPORT_PATH}
    echo "<h2>Participant ID: ${SUBJECT_ID}</h2>" >> ${HTML_REPORT_PATH}
    echo "<h2>Session ID: ${SESSION}</h2>" >> ${HTML_REPORT_PATH}

    for MODALITY in anat dwi func; do
        MOD_PATH="${SESSION_PATH}/${MODALITY}"
        if [ ! -d "${MOD_PATH}" ]; then
            continue
        fi

        echo "<h2>${MODALITY}</h2>" >> ${HTML_REPORT_PATH}

        for FILE in $(ls -a ${MOD_PATH}/*.nii.gz | grep -v sbref); do
            BASE=$(basename ${FILE} .nii.gz)
            JSON="${MOD_PATH}/${BASE}.json"
            PREFIX="${QC_SESSION_PATH}/${BASE}_${MODALITY}"
            echo ${BASE}
            # Extract 3dinfo
            3dinfo -n4 -ad3 -tr -orient -prefix ${FILE} > ${PREFIX}_info.txt
            # Check if $BASE contains echo-1 or echo-3 and skip if true
            if [[ "${BASE}" == *"_echo-1_"* || "${BASE}" == *"_echo-3_"* ]]; then
                continue
            fi
            if [ "${MODALITY}" == "anat" ]; then
                # Generate QC images
                @chauffeur_afni -ulay ${FILE}[0] -montx 8 -monty 1 -set_dicom_xyz 5 18 18 -delta_slices 10 20 10 -olay_off -prefix ${PREFIX}
                imcat -nx 1 -ny 3 -prefix ${PREFIX}.jpg ${PREFIX}*axi* ${PREFIX}*cor* ${PREFIX}*sag*
                rm ${PREFIX}*axi* ${PREFIX}*cor* ${PREFIX}*sag*

                echo "<h4>${BASE}</h4><img src='${PREFIX}.jpg' alt='${BASE}'>" >> ${HTML_REPORT_PATH}
            fi

            if [ "${MODALITY}" == "dwi" ]; then
                # DWI specific QC
                3dAutomask -overwrite -prefix ${PREFIX}_mask.nii.gz ${FILE}'[0]'
                # Intra TR motion with zipperzapper
                3dZipperZapper -prefix ${PREFIX}_zz -input ${FILE} -mask ${PREFIX}_mask.nii.gz -no_out_bad_mask

                # Make 4D plots, thanks go to PT for adding new opts to turn off sepscl/onescl/slice views to @djunct_4d_imager (v2.4)
                @djunct_4d_imager -inset ${FILE} -prefix ${PREFIX}_4d -no_onescl -no_cor
                echo "<h4>DWI EPI Distortions and Within TR Motion ${BASE} </h4><img src='${PREFIX}_4d_qc_sepscl.sag.png' alt='Saggital ${BASE}'>" >> ${HTML_REPORT_PATH}
                echo "<img src='${PREFIX}_4d_qc_sepscl.axi.png' alt='Axial ${BASE}'>" >> ${HTML_REPORT_PATH}
                echo "<h5>One slice per DWI volume, with separate scalings for each volume</h5>" >> ${HTML_REPORT_PATH}

                # Between TR motion using 3dvolreg and 1d_tool.py
                MOTION_FILE="${QC_SESSION_PATH}/dfile_rall_${BASE}.1D"
                3dvolreg -verbose -zpad 1 -1Dfile ${MOTION_FILE} -cubic -prefix NULL ${FILE}

                ENORM_FILE="${QC_SESSION_PATH}/motion_${BASE}_enorm.1D"
                1d_tool.py -infile ${MOTION_FILE} -set_nruns 1 -derivative -collapse_cols weighted_enorm -weight_vec .9 .9 .9 1 1 1 -write ${ENORM_FILE}

                if [ $(3dinfo -nv ${FILE}) -gt 9 ]; then
                    1dplot.py -sepscl -boxplot_on -reverse_order \
                              -infiles ${MOTION_FILE} ${ENORM_FILE}  \
                              -ylabels "VOLREG" "enorm"  -xlabel "vols" \
                              -title "Motion Profile: ${BASE}" -prefix ${QC_SESSION_PATH}/motion_outlier_plot_${BASE}.png

                    echo "<h4>Motion Profile - Between TR ${BASE}</h4><img src='${QC_SESSION_PATH}/motion_outlier_plot_${BASE}.png' alt='Motion and Outliers ${BASE}'>" >> ${HTML_REPORT_PATH}
                fi
            fi

            if [ "${MODALITY}" == "func" ]; then
                # Functional specific QC
                TSNR_PREFIX="${QC_SESSION_PATH}/tsnr_${BASE}"
                3dTstat -cvarinv -prefix ${TSNR_PREFIX}.nii.gz ${FILE}

                MASK_PREFIX="${QC_SESSION_PATH}/mask_${BASE}"
                3dAutomask -clfrac 0.4 -prefix ${MASK_PREFIX}.nii.gz ${TSNR_PREFIX}.nii.gz 

                @chauffeur_afni -ulay ${TSNR_PREFIX}.nii.gz -olay_off -box_focus_slices ${MASK_PREFIX}.nii.gz \
                -montx 10 -monty 1  -prefix ${TSNR_PREFIX} 

                imcat -ny 3 -prefix ${TSNR_PREFIX}.jpg ${TSNR_PREFIX}*axi* ${TSNR_PREFIX}*cor* ${TSNR_PREFIX}*sag*
                rm ${TSNR_PREFIX}*axi* ${TSNR_PREFIX}*cor* ${TSNR_PREFIX}*sag*

                echo "<h4>Temporal signal to noise ratio (TSNR) '-cvarinv' - ${BASE} </h4><img src='${TSNR_PREFIX}.jpg' alt='TSNR ${BASE}'>" >> ${HTML_REPORT_PATH}

                TSTD_PREFIX="${QC_SESSION_PATH}/tstd_${BASE}"
                3dTstat -stdev  -prefix ${TSTD_PREFIX}.nii.gz ${FILE}

                @chauffeur_afni -ulay ${TSTD_PREFIX}.nii.gz -olay_off -box_focus_slices ${MASK_PREFIX}.nii.gz \
                -montx 10 -monty 1  -prefix ${TSTD_PREFIX} #-cbar Plasma  -thr_olay 500

                imcat -ny 3 -prefix ${TSTD_PREFIX}.jpg ${TSTD_PREFIX}*axi* ${TSTD_PREFIX}*cor* ${TSTD_PREFIX}*sag*
                rm ${TSTD_PREFIX}*axi* ${TSTD_PREFIX}*cor* ${TSTD_PREFIX}*sag*

                echo "<h4>Temporal standard deviation (TSTD) '-stdev' - ${BASE}</h4><img src='${TSTD_PREFIX}.jpg' alt='TSTD ${BASE}'>" >> ${HTML_REPORT_PATH}

                OUTLIER_FILE="${QC_SESSION_PATH}/3dToutcount_fraction_${BASE}.1D"
                3dToutcount -automask -fraction -legendre -save ${QC_SESSION_PATH}/${BASE}_outlier_${MODALITY}.nii.gz ${FILE} > ${OUTLIER_FILE}

                MOTION_FILE="${QC_SESSION_PATH}/dfile_rall_${BASE}.1D"
                3dvolreg -verbose -zpad 1 -1Dfile ${MOTION_FILE} -cubic -prefix NULL ${FILE}

                CENSOR_FILE="${QC_SESSION_PATH}/${BASE}"
                1d_tool.py -infile ${MOTION_FILE} -set_nruns 1 -censor_prev_TR -censor_motion 0.3 ${CENSOR_FILE}

                ENORM_FILE="${QC_SESSION_PATH}/motion_${BASE}_enorm.1D"
                1d_tool.py -infile ${MOTION_FILE} -set_nruns 1 -derivative -collapse_cols weighted_enorm -weight_vec .9 .9 .9 1 1 1 -write ${ENORM_FILE}

                FWD_FILE="${QC_SESSION_PATH}/fwd_${BASE}_abssum.1D"
                3dTstat -abssum -prefix - ${ENORM_FILE} > ${FWD_FILE}

                TQUAL_FILE="${QC_SESSION_PATH}/3dTqual_${BASE}_range.1D"
                3dTqual -automask  -spearman  ${FILE} > ${TQUAL_FILE} 

                DVARS_FILE="${QC_SESSION_PATH}/dvars_${BASE}_range.1D"
                3dTto1D -automask -method DVARS -prefix ${DVARS_FILE} -input ${FILE}

                SRMS_FILE="${QC_SESSION_PATH}/srms_${BASE}_range.1D"
                3dTto1D -automask -method srms -prefix ${SRMS_FILE} -input ${FILE}

                # Motion plots
                1dplot.py -sepscl -boxplot_on -reverse_order \
                          -censor_files ${CENSOR_FILE}_censor.1D \
                          -infiles ${MOTION_FILE}  \
                          -ylabels "VOLREG"  -xlabel "vols" \
                          -title "3 translations and 3 rotations: ${BASE}" -prefix ${QC_SESSION_PATH}/motion_6p_${BASE}.png
                
                echo "<h4>Motion Profile - 6 params - ${BASE}</h4><img src='${QC_SESSION_PATH}/motion_6p_${BASE}.png' alt='Six parameter motion ${BASE}'>" >> ${HTML_REPORT_PATH}

                1dplot.py -sepscl -boxplot_on -reverse_order \
                          -censor_files ${CENSOR_FILE}_censor.1D \
                          -infiles ${ENORM_FILE} ${OUTLIER_FILE} ${SRMS_FILE}  \
                          -ylabels "enorm" "outliers" "dvars/gmean" -xlabel "vols" \
                          -censor_hline 0.3 0.05 0.05 \
                          -title "Enorm and Outlier plot : ${BASE}" -prefix ${QC_SESSION_PATH}/enorm_outlier_srms_plot_${BASE}.png
                
                echo "<h4>Motion Profile - summary - ${BASE}</h4><img src='${QC_SESSION_PATH}/enorm_outlier_srms_plot_${BASE}.png' alt='Enorm and Outliers ${BASE}'>" >> ${HTML_REPORT_PATH}

                1dplot -nopush -naked -THICK $(cat ${CENSOR_FILE}_CENSORTR.txt) -censor_RGB 'rgbi:1.0/0.7/0.7' -pnms 1800  ${QC_SESSION_PATH}/mot.ppm -aspect 10 ${ENORM_FILE}
                3dGrayplot -dimen 1800 400  -pvorder  -prefix ${QC_SESSION_PATH}/grayplot_${BASE}.pgm  -mask ${MASK_PREFIX}.nii.gz -input ${FILE}
                pnmcat -tb ${QC_SESSION_PATH}/mot.ppm ${QC_SESSION_PATH}/grayplot_${BASE}.pgm | pnmtopng - > ${QC_SESSION_PATH}/mot_gray_${BASE}.jpg
                rm ${QC_SESSION_PATH}/mot.ppm ${QC_SESSION_PATH}/grayplot_${BASE}.pgm 

                echo "<h4>Motion Profile - Carpet Grayplot - ${BASE}</h4><img src='${QC_SESSION_PATH}/mot_gray_${BASE}.jpg' alt='Motion_Grayplot ${BASE}'>" >> ${HTML_REPORT_PATH}
            fi
        done

        # Multi-echo processing
        if [ "${MODALITY}" == "func" ]; then
            for ECHO_2_FILE in $(ls -a ${MOD_PATH}/*_echo-2_*.nii.gz); do
                BASE=$(basename ${ECHO_2_FILE} .nii.gz)
                TASK_BASE=${BASE/_echo-2_bold/}
                
                # Collect all echoes for multi-echo data
                ECHO_FILES=()
                for ECHO_FILE in $(ls -a ${MOD_PATH}/${TASK_BASE}_echo-*.nii.gz); do
                    ECHO_FILES+=("${ECHO_FILE}")
                done

                # If there are three echoes, run tedana
                if [ ${#ECHO_FILES[@]} -eq 3 ]; then
                        echo "<h4>Multi-echo detected for ${TASK_BASE}</h4>" >> ${HTML_REPORT_PATH}
                        # Extract EchoTimes from JSON and convert to milliseconds
                        ECHO_TIMES=()
                        ECHO_TIMES_TEXT=""
                        for ECHO_FILE in "${ECHO_FILES[@]}"; do
                            JSON_FILE="${ECHO_FILE%.nii.gz}.json"
                            ECHO_TIME=$(jq '.EchoTime' ${JSON_FILE})
                            ECHO_TIME_MS=$(echo "${ECHO_TIME} * 1000" | bc)
                            ECHO_TIMES+=(${ECHO_TIME_MS})
                            ECHO_TIMES_TEXT="${ECHO_TIMES_TEXT}${ECHO_TIME_MS} ms, "
                        done
                        
                    # Remove trailing comma and space
                    ECHO_TIMES_TEXT=$(echo $ECHO_TIMES_TEXT | sed 's/, $//')

                    # Print echo times in the HTML report
                    echo "<p>Echo times: ${ECHO_TIMES_TEXT}</p>" >> ${HTML_REPORT_PATH}

                    # Run t2smap with the extracted echo times
                    t2smap -d ${MOD_PATH}/${TASK_BASE}_echo-*nii.gz -e ${ECHO_TIMES[@]} --out-dir ${QC_SESSION_PATH} --prefix ${TASK_BASE}
                    
                    T2STAR_PREFIX="${QC_SESSION_PATH}/t2star_${TASK_BASE}"
                    @chauffeur_afni -ulay ${QC_SESSION_PATH}/${TASK_BASE}_T2starmap.nii.gz -olay_off  \
                    -montx 10 -monty 1  -prefix ${T2STAR_PREFIX} 

                    imcat -ny 3 -prefix ${T2STAR_PREFIX}.jpg ${T2STAR_PREFIX}*axi* ${T2STAR_PREFIX}*cor* ${T2STAR_PREFIX}*sag*
                    rm ${T2STAR_PREFIX}*axi* ${T2STAR_PREFIX}*cor* ${T2STAR_PREFIX}*sag*
                    echo "<h4>T2* map - ${TASK_BASE} </h4><img src='${T2STAR_PREFIX}.jpg' alt='T2* map  ${TASK_BASE}'>" >> ${HTML_REPORT_PATH}

                    S0MAP_PREFIX="${QC_SESSION_PATH}/s0map_${TASK_BASE}"
                    @chauffeur_afni -ulay ${QC_SESSION_PATH}/${TASK_BASE}_S0map.nii.gz -olay_off  \
                    -montx 10 -monty 1  -prefix ${S0MAP_PREFIX} 

                    imcat -ny 3 -prefix ${S0MAP_PREFIX}.jpg ${S0MAP_PREFIX}*axi* ${S0MAP_PREFIX}*cor* ${S0MAP_PREFIX}*sag*
                    rm ${S0MAP_PREFIX}*axi* ${S0MAP_PREFIX}*cor* ${S0MAP_PREFIX}*sag*
                    echo "<h4>S0 map - ${TASK_BASE} </h4><img src='${S0MAP_PREFIX}.jpg' alt='S0 map  ${TASK_BASE}'>" >> ${HTML_REPORT_PATH}

                    1dcat ${QC_SESSION_PATH}/${TASK_BASE}_desc-confounds_timeseries.tsv'[3..7]' > "${QC_SESSION_PATH}/${TASK_BASE}_desc-confounds_timeseries.1D"
                    1dplot.py -one_graph  -legend_on -legend_labels 2 25 50 75 98 -reverse_order \
                              -infiles ${QC_SESSION_PATH}/${TASK_BASE}_desc-confounds_timeseries.1D \
                              -xlabel "vols" \
                              -title "RMSE centiles: ${TASK_BASE}" -prefix ${QC_SESSION_PATH}/${TASK_BASE}_rmse_plot.png
                    
                    echo "<h4>RMSE centiles across time for the entire brain for: ${TASK_BASE}</h4><img src='${QC_SESSION_PATH}/${TASK_BASE}_rmse_plot.png' alt='RMSE ${TASK_BASE}'>" >> ${HTML_REPORT_PATH}
                    echo "<p>Residual Mean Squared Error (RMSE) indicates the fit quality of the monoexponential T2* decay model, where lower median values for the volume suggest better data quality.</p>" >> ${HTML_REPORT_PATH}

                    RMSE_PREFIX="${QC_SESSION_PATH}/rmse_${TASK_BASE}"
                    olay_range_98=$(3dTstat -prefix - ${QC_SESSION_PATH}/${TASK_BASE}_desc-confounds_timeseries.1D'[4]'\')
                    @chauffeur_afni -ulay ${QC_SESSION_PATH}/${TASK_BASE}_desc-rmse_statmap.nii.gz -olay ${QC_SESSION_PATH}/${TASK_BASE}_desc-rmse_statmap.nii.gz  \
                    -montx 10 -monty 1  -prefix ${RMSE_PREFIX} -cbar "Plasma" -pbar_saveim ${RMSE_PREFIX}_pb -pbar_dim '32x256H' -pbar_posonly -func_range ${olay_range_98}

                    imcat -ny 3 -prefix ${RMSE_PREFIX}.jpg ${RMSE_PREFIX}*axi* ${RMSE_PREFIX}*cor* ${RMSE_PREFIX}*sag*
                    rm ${RMSE_PREFIX}*axi* ${RMSE_PREFIX}*cor* ${RMSE_PREFIX}*sag*
                    echo "<h4>RMSE map - ${TASK_BASE} </h4><img src='${RMSE_PREFIX}.jpg' alt='RMSE map  ${TASK_BASE}'>" >> ${HTML_REPORT_PATH}
                    echo "<div style='display: flex; justify-content: space-between; align-items: center;'>
                            <div style='flex: 1; text-align: right; padding-right: 0;'>0</div>
                            <div style='flex-shrink: 0;'>
                                <img src='${RMSE_PREFIX}_pb.jpg' alt='RMSE cbar ${TASK_BASE}' style='display: block;'>
                            </div>
                            <div style='flex: 1; text-align: left; padding-left: 0;'>${olay_range_98}</div>
                          </div>" >> ${HTML_REPORT_PATH}
                fi
            done
        fi
    done
 done



# 3dinfo summary
# Add header for the table
echo "<h2>3dinfo Summary</h2>" >> ${HTML_REPORT_PATH}
echo "<style>
table { 
  border-collapse: collapse; 
  width: 80%;
}
th, td { 
  border: 1px solid black; 
  padding: 1px; 
  text-align: left;
}
</style>" >> ${HTML_REPORT_PATH}
echo "<table>" >> ${HTML_REPORT_PATH}
echo "<tr>" >> ${HTML_REPORT_PATH}
echo "<th>Mat_x</th><th>Mat_y</th><th>Sli</th><th>Vol</th><th>Di</th><th>Dj</th><th>Dk</th><th>TR</th><th>Orient</th><th>Filename</th>" >> ${HTML_REPORT_PATH}
echo "</tr>" >> ${HTML_REPORT_PATH}

# Add content from info files
for file in $(find ${QC_ROOT}/sub-${SUBJECT_ID} -name '*_info.txt'| sort); do
    while IFS=$'\t' read -r mat_x mat_y sli vol di dj dk tr orient filename; do
        # Round numeric values down to two decimal places
        di=$(printf "%.3f" $di)
        dj=$(printf "%.3f" $dj)
        dk=$(printf "%.3f" $dk)
        tr=$(printf "%.3f" $tr)

        echo "<tr>" >> ${HTML_REPORT_PATH}
        echo "<td>$mat_x</td><td>$mat_y</td><td>$sli</td><td>$vol</td><td>$di</td><td>$dj</td><td>$dk</td><td>$tr</td><td>$orient</td><td>$filename</td>" >> ${HTML_REPORT_PATH}
        echo "</tr>" >> ${HTML_REPORT_PATH}
    done < "$file"
done

echo "</table>" >> ${HTML_REPORT_PATH}


# Quantitative and Qualitative Summary
echo "<table border='1' style='border-collapse: collapse; width: 100%;'>" >> ${HTML_REPORT_PATH}
echo "<tr>" >> ${HTML_REPORT_PATH}


# DWI QC Summary
echo "<h2>Diffusion MRI:</h2>" >> ${HTML_REPORT_PATH}

# Phase encoding information summary
echo "<h3>Phase Encoding Information</h3>" >> ${HTML_REPORT_PATH}
echo "<p>NB: Phase encoding polarity extraction requires the presence of PhaseEncodingDirection information in the DICOM header, not just the PhaseEncodingAxis.</p>" >> ${HTML_REPORT_PATH}
echo "<table border='1' style='border-collapse: collapse; width: 50%;'>" >> ${HTML_REPORT_PATH}
echo "<tr>" >> ${HTML_REPORT_PATH}
echo "<th>File</th><th>Phase Encoding Direction</th><th>Phase Encoding Axis</th>" >> ${HTML_REPORT_PATH}
echo "</tr>" >> ${HTML_REPORT_PATH}

for json in $(find ${SESSION_PATH}/dwi -name '*.json' |grep -v sbref); do
    PE_DIR=$(grep '"PhaseEncodingDirection":' $json | sed 's/^.*: "//;s/..$//')
    PE_AX=$(grep '"PhaseEncodingAxis":' $json | sed 's/^.*: "//;s/..$//')
    
    if [ "$PE_DIR" == "j" ]; then
        PE_DIR="P>>A"
    elif [ "$PE_DIR" == "j-" ]; then
        PE_DIR="A>>P"
    elif [ "$PE_DIR" == "i" ]; then
        PE_DIR="R>>L"
    elif [ "$PE_DIR" == "i-" ]; then
        PE_DIR="L>>R"
    else
        PE_DIR="N/A"
    fi
    
    if [ "$PE_AX" == "j" ] || [ "$PE_AX" == "j-" ]; then
        PE_AX="COL"
    elif [ "$PE_AX" == "i" ] || [ "$PE_AX" == "i-" ]; then
        PE_AX="ROW"
    else
        PE_AX="N/A"
    fi
    
    echo "<tr>" >> ${HTML_REPORT_PATH}
    echo "<td>$(basename $json .json).nii.gz</td><td>${PE_DIR}</td><td>${PE_AX}</td>" >> ${HTML_REPORT_PATH}
    echo "</tr>" >> ${HTML_REPORT_PATH}
done

echo "</table>" >> ${HTML_REPORT_PATH}


# Start the table for the DWI QC results
echo "<h3>Diffusion MRI: Motion/Slice-Drop Corruption Summary</h3>" >> ${HTML_REPORT_PATH}
echo "<table border='1' style='border-collapse: collapse; width: 80%;'>" >> ${HTML_REPORT_PATH}
echo "<tr>" >> ${HTML_REPORT_PATH}
echo "<th>File</th><th>Corrupted Volumes (Count/Total)</th><th>Usable b0 Volumes</th><th>Status</th><th>Volumes Requiring Visual Inspection</th>" >> ${HTML_REPORT_PATH}
echo "</tr>" >> ${HTML_REPORT_PATH}

for zzbad in $(find ${QC_SESSION_PATH} -name '*zz_badlist.txt'); do
    DWI_LIST=$(basename $zzbad _dwi_zz_badlist.txt)
    DWI_BAD_COUNT=$(wc -l < $zzbad)
    DWI_BAD_LIST=$(cat $zzbad)
    NV=$(3dinfo -nv ${SESSION_PATH}/dwi/${DWI_LIST}.nii.gz)
    XV=$((NV / 5))
    
    # Count usable b0 volumes
    BVAL_FILE=${SESSION_PATH}/dwi/${DWI_LIST}.bval
    USABLE_B0=0
    
    if [ -f "$BVAL_FILE" ]; then
        BVALS=($(cat $BVAL_FILE))
        for i in "${!BVALS[@]}"; do
            if (( $(echo "${BVALS[$i]} < 10" | bc -l) )); then
                if ! grep -q -w "$i" "$zzbad"; then
                    USABLE_B0=$((USABLE_B0 + 1))
                fi
            fi
        done
    else
        USABLE_B0="N/A"
    fi
    
    # Determine the status (Pass/Fail)
    if [ "$DWI_BAD_COUNT" -lt "$XV" ] && [ "$USABLE_B0" -ge 1 ]; then    
        STATUS="Pass"
    else
        STATUS="Fail"
    fi
    
    # Determine volumes requiring visual inspection
    if [ "$DWI_BAD_COUNT" -gt 0 ]; then
        VISUAL_INSPECTION="$DWI_BAD_LIST"
    else
        VISUAL_INSPECTION="None"
    fi
    
    echo "<tr>" >> ${HTML_REPORT_PATH}
    echo "<td>${DWI_LIST}.nii.gz</td><td>$DWI_BAD_COUNT / $NV</td><td>$USABLE_B0</td><td>$STATUS</td><td>$VISUAL_INSPECTION</td>" >> ${HTML_REPORT_PATH}
    echo "</tr>" >> ${HTML_REPORT_PATH}
done

# Close the table
echo "</table>" >> ${HTML_REPORT_PATH}


# Close the table
echo "</table>" >> ${HTML_REPORT_PATH}

# Functional QC Summary
echo "" >> ${HTML_REPORT_PATH}
echo "<h2>Resting-state fMRI:</h2>" >> ${HTML_REPORT_PATH}

# Loop through each BOLD file, sorted
for bold in $(find ${SESSION_PATH}/func -name '*bold.nii.gz' | sort); do
    BASE=$(basename "$bold" .nii.gz)
    # Check if $BASE contains echo-1 or echo-3 and skip if true
    if [[ "${BASE}" == *"_echo-1_"* || "${BASE}" == *"_echo-3_"* ]]; then
        continue
    fi
    # Calculate metrics as in your original script
    aor=$(3dTstat -prefix - ${QC_SESSION_PATH}/3dToutcount_fraction_${BASE}.1D\')
    aqi=$(3dTstat -prefix - ${QC_SESSION_PATH}/3dTqual_${BASE}_range.1D\')
    FD=$(3dTstat -prefix - ${QC_SESSION_PATH}/fwd_${BASE}_abssum.1D\')
    DVARS=$(3dTstat -prefix - ${QC_SESSION_PATH}/srms_${BASE}_range.1D\')

    # GSR Calculation
    direction="xy"
    tmp_code="$(3dnewid -fun11)"
    tmp_dir="${QC_SESSION_PATH}/__tmp_gsr_${tmp_code}"
    mkdir -p "${tmp_dir}"

    mean_file="${tmp_dir}/${BASE}_mean.nii.gz"
    3dTstat -mean -prefix "$mean_file" "$bold"
    mask_file="${tmp_dir}/${BASE}_mask.nii.gz"
    3dAutomask -prefix "$mask_file" "$mean_file"
    summary_file="${QC_SESSION_PATH}/${BASE}_GSR.txt"

    for dir in $(echo "$direction" | sed -e 's/\(.\)/\1 /g'); do
        mask_temp1="${tmp_dir}/${BASE}_${dir}_pad1.nii.gz"
        mask_temp2="${tmp_dir}/${BASE}_${dir}_pad2.nii.gz"
        shifted_mask="${tmp_dir}/${BASE}_${dir}_shifted.nii.gz"
        ghost_mask="${tmp_dir}/${BASE}_${dir}_ghost.nii.gz"
        non_ghost_mask="${tmp_dir}/${BASE}_${dir}_non_ghost.nii.gz"

        case $dir in
            x)
                num_slices=$(3dinfo -n4 "$mask_file" | awk '{print $1}')
                shift=$((num_slices / 2))
                3dZeropad -A $shift -P -$shift -prefix "$mask_temp1" "$mask_file"
                3dZeropad -A -$shift -P $shift -prefix "$mask_temp2" "$mask_file"
                ;;
            y)
                num_slices=$(3dinfo -n4 "$mask_file" | awk '{print $2}')
                shift=$((num_slices / 2))
                3dZeropad -L $shift -R -$shift -prefix "$mask_temp1" "$mask_file"
                3dZeropad -L -$shift -R $shift -prefix "$mask_temp2" "$mask_file"
                ;;
        esac

        3drefit -duporigin "$mask_file" "$mask_temp1"
        3drefit -duporigin "$mask_file" "$mask_temp2"
        3dcalc -a "$mask_temp1" -b "$mask_temp2" -expr 'a+b' -prefix "$shifted_mask"
        3dcalc -a "$shifted_mask" -b "$mask_file" -expr 'a*(1-b)' -prefix "$ghost_mask"
        3dcalc -a "$ghost_mask" -b "$mask_file" -expr '(1-a-b)' -prefix "$non_ghost_mask"

        ghost_mean=$(3dmaskave -mask "$ghost_mask" -quiet "$mean_file")
        non_ghost_mean=$(3dmaskave -mask "$non_ghost_mask" -quiet "$mean_file")
        signal_median=$(3dBrickStat -mask "$mask_file" -median "$mean_file" | awk '{print $2}')
        gsr_value=$(echo "scale=4; ($ghost_mean - $non_ghost_mean) / $signal_median" | bc -l)

        echo "GSR_${dir}: ${gsr_value}" | tee -a "$summary_file"
    done

    GSR_X=$(grep 'GSR_x' "$summary_file" | awk '{print $2}')
    GSR_Y=$(grep 'GSR_y' "$summary_file" | awk '{print $2}')

    # Generate HTML report
 
    echo "<h3>${BASE}.nii.gz</h3>" >> ${HTML_REPORT_PATH}
    echo "<table border='1' style='border-collapse: collapse; width: 50%;'>" >> ${HTML_REPORT_PATH}
    echo "<tr><th>Measure</th><th>Value</th></tr>" >> ${HTML_REPORT_PATH}
    echo "<tr><td>Mean Framewise Displacement (FD) [Motion Index]</td><td>$FD</td></tr>" >> ${HTML_REPORT_PATH}
    echo "<tr><td>Mean DVARS (scaled by glob mean) [sDVARS Index]</td><td>$DVARS</td></tr>" >> ${HTML_REPORT_PATH}
    echo "<tr><td>Mean Outlier Vox-to-Vol Fraction [Outlier Index]</td><td>$aor</td></tr>" >> ${HTML_REPORT_PATH}
    echo "<tr><td>Mean Distance to Median Volume [Quality Index]</td><td>$aqi</td></tr>" >> ${HTML_REPORT_PATH}
    echo "<tr><td>Ghost to Signal Ratio (GSR) - X Direction</td><td>$GSR_X</td></tr>" >> ${HTML_REPORT_PATH}
    echo "<tr><td>Ghost to Signal Ratio (GSR) - Y Direction</td><td>$GSR_Y</td></tr>" >> ${HTML_REPORT_PATH}
    echo "</table>" >> ${HTML_REPORT_PATH}

    echo "$FD 0.3" | awk '{ if ($1 > $2) print "<p>Result --> Mean FD Motion exceeds acceptable thresholds (<0.3mm)</p>"; else print "<p>Result --> Mean FD Motion is within acceptable thresholds</p>"}' >> ${HTML_REPORT_PATH}

    echo "<h4>Censoring at different motion limits</h4>" >> ${HTML_REPORT_PATH}
    echo "<table border='1' style='border-collapse: collapse; width: 20%;'>" >> ${HTML_REPORT_PATH}
    echo "<tr><th>Motion Limit</th><th>Number of Censored Time Points</th></tr>" >> ${HTML_REPORT_PATH}

    # Define the limits
    limits=(0.2 0.3 0.4 0.5)
    # Loop through the limits and calculate the number of censored time points
    for maxm in "${limits[@]}"; do
        ncen=$(1d_tool.py -infile ${QC_SESSION_PATH}/dfile_rall_${BASE}.1D -set_nruns 1 -quick_censor_count $maxm)
        echo "<tr><td>$maxm</td><td>$ncen</td></tr>" >> ${HTML_REPORT_PATH}
    done
    echo "</table>" >> ${HTML_REPORT_PATH}

    # Cleanup temporary GSR files
    rm -r "$tmp_dir"
done

# Cleanup temporary files
find ${QC_ROOT}/sub-${SUBJECT_ID} -type d -name "__tmp_chauf_*" -exec rm -rf {} +
#Final Pass/Fail Summary Table
echo "<h2>Final QC Decisions </h2>" >> ${HTML_REPORT_PATH}
echo "<style>
table { 
  border-collapse: collapse; 
  width: 100%;
}
th, td { 
  border: 1px solid black; 
  padding: 5px; 
  text-align: center;
}
button {
  font-size: 16px;
  padding: 10px 20px;
  margin: 5px;
  border-radius: 5px;
  border: 1px solid #ccc;
  cursor: pointer;
}
button:hover {
  background-color: #f0f0f0;
}
button.ok { 
  background-color: lightgreen; 
}
button.warning { 
  background-color: orange; 
}
button.reject { 
  background-color: lightcoral; 
}
textarea {
  width: 90%;
  padding: 5px;
  border-radius: 5px;
  border: 1px solid #ccc;
}
.save-button {
  font-size: 18px;
  padding: 15px 30px;
  background-color: #28a745;
  color: white;
  border-radius: 10px;
  border: none;
  cursor: pointer;
}
.save-button:hover {
  background-color: #218838;
}
</style>" >> ${HTML_REPORT_PATH}


# Loop over modalities to create separate tables
for MODALITY in anat dwi func fmap; do
    echo "<h3>${MODALITY}</h3>" >> ${HTML_REPORT_PATH}
    echo "<table id='${MODALITY}-summary-table'>" >> ${HTML_REPORT_PATH}
    echo "<tr><th>Filename</th><th>QC Status</th><th>Comments</th></tr>" >> ${HTML_REPORT_PATH}

    # Add rows for each file in the BIDS folder under the current modality
    for FILE in $(find ${BIDS_ROOT}/sub-${SUBJECT_ID}/${SESSION}/${MODALITY} -name "*.nii.gz" | sort); do
        FILENAME=$(basename "$FILE")
        echo "<tr>
                <td>$FILENAME</td>
                <td>
                    <button onclick=\"markLevel('$FILENAME', 2, this)\">OK</button>
                    <button onclick=\"markLevel('$FILENAME', 1, this)\">Borderline/Warning</button>
                    <button onclick=\"markLevel('$FILENAME', 0, this)\">Reject/Problem</button>
                    <span id='${FILENAME}_result'>Not Reviewed</span>
                </td>
                <td><textarea id='${FILENAME}_comment' rows='2' cols='40'></textarea></td>
              </tr>" >> ${HTML_REPORT_PATH}
    done
    # Add the "Pass All" and "Fail All" buttons for the modality
    echo "<tr>
            <td colspan='3' style='text-align:center;'>
                <!-- Placeholders for the speed rating if needed -->
                <button onclick=\"markAllLevel('${MODALITY}', 2)\">Set All to OK</button>
                <button onclick=\"markAllLevel('${MODALITY}', 1)\">Set All to Borderline/Warning</button>
                <button onclick=\"markAllLevel('${MODALITY}', 0)\">Set All to Reject/Problem</button>
            </td>
          </tr>" >> ${HTML_REPORT_PATH}

    # End the table
    echo "</table>" >> ${HTML_REPORT_PATH}
done

# Add the submit button to save the results
echo "<button class='save-button' onclick=\"saveReport()\">Submit QC and Save Report</button>" >> ${HTML_REPORT_PATH}

# JavaScript for handling the QC level buttons and comments
echo "<script>
    function markLevel(file, level, button) {
        var levelText = '';
        if (level === 0) {
            levelText = 'Reject/Problem';
            button.classList.add('reject');
        } else if (level === 1) {
            levelText = 'Borderline/Warning';
            button.classList.add('warning');
        } else if (level === 2) {
            levelText = 'OK';
            button.classList.add('ok');
        }

        // Remove color classes from other buttons
        var buttons = button.parentElement.querySelectorAll('button');
        buttons.forEach(function(btn) {
            if (btn !== button) {
                btn.classList.remove('ok', 'warning', 'reject');
            }
        });

        document.getElementById(file + '_result').innerText = levelText;
        document.getElementById(file + '_result').setAttribute('data-level', level);
    }

    function markAllLevel(modality, level) {
        var rows = document.querySelectorAll('#' + modality + '-summary-table tr');
        for (var i = 1; i < rows.length; i++) {
            var file = rows[i].cells[0].innerText;
            var buttons = rows[i].cells[1].querySelectorAll('button');
            buttons.forEach(function(btn) {
                if (btn.textContent === 'OK' && level === 2) {
                    markLevel(file, level, btn);
                } else if (btn.textContent === 'Borderline/Warning' && level === 1) {
                    markLevel(file, level, btn);
                } else if (btn.textContent === 'Reject/Problem' && level === 0) {
                    markLevel(file, level, btn);
                }
            });
        }
    }

    function saveReport() {
        var reportContent = '';
        ['anat', 'dwi', 'func', 'fmap'].forEach(function(modality) {
            var rows = document.querySelectorAll('#' + modality + '-summary-table tr');
            reportContent += modality.toUpperCase() + ' FILES:\n';
            for (var i = 1; i < rows.length; i++) {
                var cells = rows[i].cells;
                if (cells.length >= 2) { // Ensure there are at least 2 cells
                    var file = cells[0].innerText;
                    var levelSpan = cells[1].querySelector('span');
                    if (levelSpan) {
                        var level = levelSpan.getAttribute('data-level');
                        var comment = document.getElementById(file + '_comment').value;
                        reportContent += file + ' : ' + level + ' | Comment: ' + comment + '\n';
                    } else {
                        console.error('Level span not found for file:', file);
                    }
                } else {
                    console.error('Row structure unexpected:', rows[i]);
                }
            }
            reportContent += '\n';
        });

        var element = document.createElement('a');
        element.setAttribute('href', 'data:text/plain;charset=utf-8,' + encodeURIComponent(reportContent));
        element.setAttribute('download', 'QC_Report_sub-${SUBJECT_ID}_${SESSION}.txt');
        document.body.appendChild(element);
        element.click();
        document.body.removeChild(element);
    }
</script>" >> ${HTML_REPORT_PATH}


# Capture end time
end_time=$(date +%s)

# Calculate duration
duration=$((end_time - start_time))
minutes=$((duration / 60))
seconds=$((duration % 60))

# Add duration to the HTML report
echo "<p>QC page generated in ${minutes} minutes and ${seconds} seconds.</p>" >> ${HTML_REPORT_PATH}

# Close the HTML document
echo "</body></html>" >> ${HTML_REPORT_PATH}

echo "QC Report generated at ${HTML_REPORT_PATH}"
