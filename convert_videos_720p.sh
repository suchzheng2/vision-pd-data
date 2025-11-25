#!/bin/bash
#SBATCH --job-name=convert_videos_720p
#SBATCH --out="jobs/slurm-%j_convert_videos_720p.out"
#SBATCH --partition=day
#SBATCH --time=1-00:00:00
#SBATCH --cpus-per-task=1
#SBATCH --requeue
#SBATCH --mem=100G
#SBATCH --mail-type=ALL

module load FFmpeg 

INPUT_ZIP="/gpfs/milgram/project/scherzer/fc537/vision_PD/ClinicalD/videos_all.zip"
OUTPUT_ZIP="/gpfs/milgram/project/scherzer/fc537/vision_PD/ClinicalD/videos_all_720p.zip"
TEMP_DIR="./temp_conversion_$$"
LOG_FILE="conversion_log_$(date +%Y%m%d_%H%M%S).txt"

# Check arguments
if [ -z "$INPUT_ZIP" ] || [ -z "$OUTPUT_ZIP" ]; then
    echo "Usage: $0 <input.zip> <output.zip>"
    echo "Example: $0 videos_all.zip videos_all_720p.zip"
    exit 1
fi

# Check if input exists
if [ ! -f "$INPUT_ZIP" ]; then
    echo "Error: Input file $INPUT_ZIP not found"
    exit 1
fi

# Check if ffmpeg is available
if ! command -v ffmpeg &> /dev/null; then
    echo "Error: ffmpeg is not installed."
    echo "Install with: module load FFmpeg  (on HPC)"
    echo "Or: sudo apt-get install ffmpeg  (on Ubuntu)"
    exit 1
fi

# Create temp directory
mkdir -p "$TEMP_DIR"

echo "========================================" | tee -a "$LOG_FILE"
echo "Video Conversion to 720p" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"
echo "Start time: $(date)" | tee -a "$LOG_FILE"
echo "Input: $INPUT_ZIP" | tee -a "$LOG_FILE"
echo "Output: $OUTPUT_ZIP" | tee -a "$LOG_FILE"
echo "Log file: $LOG_FILE" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Get list of all video files (skip ._ metadata files and directories)
echo "Analyzing archive..." | tee -a "$LOG_FILE"
VIDEO_LIST=$(unzip -Z1 "$INPUT_ZIP" | grep -E '\.(MOV|mov|mp4|MP4)$' | grep -v '/\._')

# Count total videos
TOTAL_VIDEOS=$(echo "$VIDEO_LIST" | wc -l)
CURRENT=0
FAILED=0
SUCCESS=0

echo "Found $TOTAL_VIDEOS video files to convert" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Start time for ETA calculation
START_TIME=$(date +%s)

# Process each video
echo "$VIDEO_LIST" | while IFS= read -r VIDEO_PATH; do
    # Skip empty lines
    [ -z "$VIDEO_PATH" ] && continue
    
    CURRENT=$((CURRENT + 1))
    
    # Calculate progress and ETA
    PERCENT=$((CURRENT * 100 / TOTAL_VIDEOS))
    ELAPSED=$(($(date +%s) - START_TIME))
    if [ $CURRENT -gt 0 ]; then
        AVG_TIME=$((ELAPSED / CURRENT))
        REMAINING=$((TOTAL_VIDEOS - CURRENT))
        ETA_SECONDS=$((AVG_TIME * REMAINING))
        ETA_HOURS=$((ETA_SECONDS / 3600))
        ETA_MINS=$(((ETA_SECONDS % 3600) / 60))
        ETA_STR="${ETA_HOURS}h ${ETA_MINS}m"
    else
        ETA_STR="calculating..."
    fi
    
    echo "========================================" | tee -a "$LOG_FILE"
    echo "[$CURRENT/$TOTAL_VIDEOS - ${PERCENT}%] ETA: $ETA_STR" | tee -a "$LOG_FILE"
    echo "File: $VIDEO_PATH" | tee -a "$LOG_FILE"
    
    # Extract the specific file
    echo "  Extracting..." | tee -a "$LOG_FILE"
    unzip -q -o "$INPUT_ZIP" "$VIDEO_PATH" -d "$TEMP_DIR" 2>&1 | tee -a "$LOG_FILE"
    
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo "  ERROR: Failed to extract" | tee -a "$LOG_FILE"
        FAILED=$((FAILED + 1))
        continue
    fi
    
    INPUT_FILE="$TEMP_DIR/$VIDEO_PATH"
    
    # Keep original filename but save to same directory
    FILENAME=$(basename "$VIDEO_PATH")
    DIRNAME=$(dirname "$VIDEO_PATH")
    OUTPUT_FILE="$TEMP_DIR/$DIRNAME/${FILENAME%.*}_720p.${FILENAME##*.}"
    
    # Get original resolution
    ORIG_RES=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$INPUT_FILE" 2>/dev/null)
    ORIG_SIZE=$(du -h "$INPUT_FILE" | cut -f1)
    echo "  Original: ${ORIG_RES} (${ORIG_SIZE})" | tee -a "$LOG_FILE"
    
    # Convert to 720p
    echo "  Converting to 720p..." | tee -a "$LOG_FILE"
    ffmpeg -i "$INPUT_FILE" \
           -vf "scale=-2:720" \
           -c:v libx264 \
           -crf 23 \
           -preset medium \
           -c:a aac \
           -b:a 128k \
           -movflags +faststart \
           "$OUTPUT_FILE" \
           -y -loglevel error -stats 2>&1 | tee -a "$LOG_FILE"
    
    if [ ${PIPESTATUS[0]} -eq 0 ] && [ -f "$OUTPUT_FILE" ]; then
        NEW_SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
        NEW_RES=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$OUTPUT_FILE" 2>/dev/null)
        REDUCTION=$(echo "scale=1; (1 - $(stat -f%z "$OUTPUT_FILE" 2>/dev/null || stat -c%s "$OUTPUT_FILE") / $(stat -f%z "$INPUT_FILE" 2>/dev/null || stat -c%s "$INPUT_FILE")) * 100" | bc 2>/dev/null || echo "N/A")
        
        echo "  Converted: ${NEW_RES} (${NEW_SIZE}) - ${REDUCTION}% reduction" | tee -a "$LOG_FILE"
        
        # Add to output zip preserving directory structure
        OUTPUT_PATH="$DIRNAME/${FILENAME%.*}_720p.${FILENAME##*.}"
        (cd "$TEMP_DIR" && zip -q -9 "$OUTPUT_ZIP" "$OUTPUT_PATH") 2>&1 | tee -a "$LOG_FILE"
        
        if [ ${PIPESTATUS[0]} -eq 0 ]; then
            echo "  ✓ Successfully added to archive" | tee -a "$LOG_FILE"
            SUCCESS=$((SUCCESS + 1))
        else
            echo "  ERROR: Failed to add to archive" | tee -a "$LOG_FILE"
            FAILED=$((FAILED + 1))
        fi
        
        # Clean up converted file
        rm -f "$OUTPUT_FILE"
    else
        echo "  ERROR: Conversion failed" | tee -a "$LOG_FILE"
        FAILED=$((FAILED + 1))
    fi
    
    # Always clean up extracted input file
    rm -f "$INPUT_FILE"
    
    echo "" | tee -a "$LOG_FILE"
done

# Copy folder structure to new zip
echo "Creating folder structure in output archive..." | tee -a "$LOG_FILE"
unzip -Z1 "$INPUT_ZIP" | grep '/$' | while IFS= read -r DIR; do
    [ -z "$DIR" ] && continue
    mkdir -p "$TEMP_DIR/$DIR"
    (cd "$TEMP_DIR" && zip -q "$OUTPUT_ZIP" "$DIR" 2>/dev/null)
done

# Clean up
echo "Cleaning up temporary files..." | tee -a "$LOG_FILE"
rm -rf "$TEMP_DIR"

echo "" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"
echo "Conversion Complete!" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"
echo "End time: $(date)" | tee -a "$LOG_FILE"
echo "Total videos: $TOTAL_VIDEOS" | tee -a "$LOG_FILE"
echo "Successful: $SUCCESS" | tee -a "$LOG_FILE"
echo "Failed: $FAILED" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Original archive: $(du -h "$INPUT_ZIP" | cut -f1)" | tee -a "$LOG_FILE"
if [ -f "$OUTPUT_ZIP" ]; then
    echo "New archive: $(du -h "$OUTPUT_ZIP" | cut -f1)" | tee -a "$LOG_FILE"
fi
echo "" | tee -a "$LOG_FILE"
echo "Log saved to: $LOG_FILE" | tee -a "$LOG_FILE"