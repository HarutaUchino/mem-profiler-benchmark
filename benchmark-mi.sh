#!/bin/bash

# Set to exit the script immediately when an error occurs
set -u
set -o pipefail

# Set the maximum number of retries
MAX_RETRIES=3

# Function to display error messages (does not terminate the script)
error_exit() {
    echo "Error: $1" >&2
}

# Directory list of mimalloc libraries
MIMALLOC_DIRS=(
    "/path/to/mimalloc-2.1.7/out/mimalloc-default-arena_reserve_1GB"
)

# Source file and include directory of the test program
TEST_PROGRAM_SRC="../test/xmalloc-test.c"
MIMALLOC_INCLUDE="/path/to/mimalloc-2.1.7/include"
# List of the number of threads and object sizes
WORKERS_LIST=(8)  # Add or change as needed
#OBJECT_SIZE_LIST=(8 16 32 64 128 256 512 1024 2048 4096)
OBJECT_SIZE_LIST=(64)

RUN_TIME=300
RUN_COUNT=10

# Create output directory
TODAY=$(date '+%Y-%m-%d-%H')
BASE_OUTPUT_DIR="../results_test/$TODAY"
mkdir -p "$BASE_OUTPUT_DIR"
chmod 777 "$BASE_OUTPUT_DIR"

# Initialize final results CSV file
FINAL_RESULTS_FILE="$BASE_OUTPUT_DIR/final_results.csv"
echo "mimalloc_version,workers,object_size,avg_VmPeak_MB,avg_VmSize_MB,avg_VmHWM_MB,avg_VmRSS_MB,avg_Free_Sec_M" > "$FINAL_RESULTS_FILE"

# Initialize statistics CSV file
FINAL_STATS_FILE="$BASE_OUTPUT_DIR/final_statistics.csv"
echo "mimalloc_version,workers,object_size,Metric,Average" > "$FINAL_STATS_FILE"

# Function to get memory information
get_memory_info() {
    local pid=$1
    local log_file=$2
    if [ -d /proc/$pid ]; then
        if [ -f /proc/$pid/status ]; then
            # Ensure values are retrieved correctly
            VmPeak=$(sed -n 's/VmPeak:[[:space:]]*\([0-9]*\).*/\1/p' /proc/$pid/status)
            VmSize=$(sed -n 's/VmSize:[[:space:]]*\([0-9]*\).*/\1/p' /proc/$pid/status)
            VmHWM=$(sed -n 's/VmHWM:[[:space:]]*\([0-9]*\).*/\1/p' /proc/$pid/status)
            VmRSS=$(sed -n 's/VmRSS:[[:space:]]*\([0-9]*\).*/\1/p' /proc/$pid/status)

            # More accurate timestamp (up to milliseconds)
            Timestamp=$(date '+%Y-%m-%d %H:%M:%S.%3N')
            echo "$Timestamp,$VmPeak,$VmSize,$VmHWM,$VmRSS" >> "$log_file"
        fi
    fi
}

# Function to extract free/sec value
extract_free_sec() {
    local output_txt=$1
    free_sec=$(grep "free/sec:" "$output_txt" | awk -F'free/sec: ' '{print $2}' | awk '{print $1}')
    # Maintain "0.xxxx" format
    echo "$free_sec"
}

# Function to calculate average
calculate_statistics() {
    local values=("$@")
    local count=${#values[@]}

    if [ "$count" -lt 1 ]; then
        echo "N/A"
        return
    fi

    # Extract only numeric values
    local numeric_values=()
    for val in "${values[@]}"; do
        if [[ "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            numeric_values+=("$val")
        fi
    done

    local numeric_count=${#numeric_values[@]}

    if [ "$numeric_count" -lt 1 ]; then
        echo "N/A"
        return
    fi

    # Calculate average
    local sum=0
    for val in "${numeric_values[@]}"; do
        sum=$(echo "$sum + $val" | bc -l)
    done
    local mean=$(echo "scale=6; $sum / $numeric_count" | bc -l)

    # Output result (up to 6 decimal places)
    printf "%.6f\n" "$mean"
}

# Function to convert units from kB to MB and format to 3 decimal places
convert_kb_to_mb() {
    local value=$1
    if [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "scale=3; $value / 1024" | bc
    else
        echo "N/A"
    fi
}

# Function to run a test case
run_test_case() {
    local mimalloc_dir=$1
    local mimalloc_version=$2
    local workers=$3
    local object_size=$4

    OUTPUT_DIR="$BASE_OUTPUT_DIR/mimalloc_$mimalloc_version/w${workers}_s${object_size}"
    mkdir -p "$OUTPUT_DIR"

    COMPILED_TEST_PROGRAM="$OUTPUT_DIR/xmalloc-test"

    # Limit symbolic link creation to once
    if [ ! -f "$mimalloc_dir/libmimalloc.so.2" ]; then
        ln -s "libmimalloc.so.2.1" "$mimalloc_dir/libmimalloc.so.2" || {
            echo "Failed to create symlink libmimalloc.so.2 in $mimalloc_dir" >&2
            return 1
        }
    fi

    free_sec_values=()
    vmpeak_last_values=()
    vmsize_last_values=()  # Changed: Use the last value
    vmhwm_last_values=()
    vmrss_last_values=()   # Changed: Use the last value

    # Initialize arrays to store average values of VmSize and VmRSS for each run
    vmsize_run_averages=()
    vmrss_run_averages=()

    # Flag for compiling only once
    COMPILE_SUCCESS=0

    for run in $(seq 1 $RUN_COUNT); do
        # Clear system cache
        sync
        echo 3 > /proc/sys/vm/drop_caches
        swapoff -a && swapon -a  # Reset swap
        sleep 60  # Wait for system stabilization

        # Set LD_PRELOAD
        unset LD_PRELOAD
        export LD_PRELOAD="$mimalloc_dir/libmimalloc.so.2.1"

        # Compile if not already compiled
        if [ $COMPILE_SUCCESS -eq 0 ]; then
            # Add optimization flags to the compilation of the test program
            gcc -O2 -w -o "$COMPILED_TEST_PROGRAM" "$TEST_PROGRAM_SRC" \
                -I"$MIMALLOC_INCLUDE" \
                -L"$mimalloc_dir" \
                -lmimalloc -lpthread
            if [ $? -ne 0 ]; then
                echo "Compilation failed for mimalloc version $mimalloc_version" >&2
                return 1
            fi
            COMPILE_SUCCESS=1
        fi

        # Save ldd output
        ldd "$COMPILED_TEST_PROGRAM" > "$OUTPUT_DIR/ldd_output.txt"
        if [ $? -ne 0 ]; then
            echo "ldd failed for $COMPILED_TEST_PROGRAM" >&2
            return 1
        fi

        RUN_DIR="$OUTPUT_DIR/run$run"
        mkdir -p "$RUN_DIR"

        LOG_FILE="$RUN_DIR/memory_log_test.csv"
        OUTPUT_TXT="$RUN_DIR/test_output.txt"

        echo "Timestamp,VmPeak (kB),VmSize (kB),VmHWM (kB),VmRSS (kB)" > "$LOG_FILE"

        echo "ldd output:" > "$OUTPUT_TXT"
        cat "$OUTPUT_DIR/ldd_output.txt" >> "$OUTPUT_TXT"

        echo "test program output:" >> "$OUTPUT_TXT"

        # Run the test program in the foreground
        "$COMPILED_TEST_PROGRAM" -w "$workers" -t "$RUN_TIME" -s "$object_size" >> "$OUTPUT_TXT" 2>&1 &
        TEST_PID=$!

        # Memory information collection in background with subshell
        (
            while kill -0 "$TEST_PID" 2>/dev/null; do
                get_memory_info "$TEST_PID" "$LOG_FILE"
                sleep 1.0  # Exactly 1 second interval
            done
        ) &
        MEMORY_COLLECTOR_PID=$!

        # Wait for the test program to finish
        wait "$TEST_PID"
        TEST_EXIT_STATUS=$?
        # Wait for the memory information collection process to finish
        wait "$MEMORY_COLLECTOR_PID"

        if [ $TEST_EXIT_STATUS -ne 0 ]; then
            echo "Test program exited with error for run $run." >&2
            return 1
        fi

        # Extract free/sec value
        free_sec=$(extract_free_sec "$OUTPUT_TXT")
        free_sec_values+=("$free_sec")

        # Get the last values of VmPeak, VmSize, VmHWM, VmRSS (excluding empty lines)
        last_vmpeak=$(awk -F',' 'NF >= 4 {gsub(/^ +| +$/, "", $2); if ($2 ~ /^[0-9]+$/) print $2}' "$LOG_FILE" | tail -n1 | xargs)
        last_vmsize=$(awk -F',' 'NF >= 4 {gsub(/^ +| +$/, "", $3); if ($3 ~ /^[0-9]+$/) print $3}' "$LOG_FILE" | tail -n1 | xargs)
        last_vmhwm=$(awk -F',' 'NF >= 4 {gsub(/^ +| +$/, "", $4); if ($4 ~ /^[0-9]+$/) print $4}' "$LOG_FILE" | tail -n1 | xargs)
        last_vmrss=$(awk -F',' 'NF >= 4 {gsub(/^ +| +$/, "", $5); if ($5 ~ /^[0-9]+$/) print $5}' "$LOG_FILE" | tail -n1 | xargs)

        vmpeak_last_values+=("$last_vmpeak")
        vmsize_last_values+=("$last_vmsize")  # Changed: Add the last value to the array
        vmhwm_last_values+=("$last_vmhwm")
        vmrss_last_values+=("$last_vmrss")    # Changed: Add the last value to the array

        # Calculate the total number of data lines (excluding header line)
        total_data_lines=$(($(wc -l < "$LOG_FILE") - 1))
        # Set the start and end lines (excluding the first 5 seconds and the last 5 seconds)
        start_line=$((2 + 5))  # +2 to include the header line
        end_line=$((1 + total_data_lines - 5))

        # Calculate the average of VmSize and VmRSS (only for the specified range)
        avg_vmsize=$(awk -F',' -v start="$start_line" -v end="$end_line" 'BEGIN {sum=0; count=0}
            NR>=start && NR<=end && $3 ~ /^[0-9]+$/ {
                sum += $3
                count++
            }
            END {
                if(count > 0) printf "%.6f", sum / count
                else print "N/A"
            }' "$LOG_FILE")
        avg_vmrss=$(awk -F',' -v start="$start_line" -v end="$end_line" 'BEGIN {sum=0; count=0}
            NR>=start && NR<=end && $5 ~ /^[0-9]+$/ {
                sum += $5
                count++
            }
            END {
                if(count > 0) printf "%.6f", sum / count
                else print "N/A"
            }' "$LOG_FILE")

        # Add the average values for each run to the arrays
        vmsize_run_averages+=("$avg_vmsize")
        vmrss_run_averages+=("$avg_vmrss")

        echo "Run $run completed. Memory usage logged in $LOG_FILE and output saved in $OUTPUT_TXT."
        echo "Average VmSize: $avg_vmsize"
        echo "Average VmRSS: $avg_vmrss"
        # Reset LD_PRELOAD
        unset LD_PRELOAD

        # Extend the pause time after each run (30 seconds)
        sleep 180
    done

    # Calculate statistics for each metric
    stats_vmpeak=$(calculate_statistics "${vmpeak_last_values[@]}")
    stats_vmsize=$(calculate_statistics "${vmsize_run_averages[@]}")  # Corrected: Use the average values for each run
    stats_vmhwm=$(calculate_statistics "${vmhwm_last_values[@]}")
    stats_vmrss=$(calculate_statistics "${vmrss_run_averages[@]}")    # Corrected: Use the average values for each run
    stats_free_sec=$(calculate_statistics "${free_sec_values[@]}")

    mean_vmpeak="$stats_vmpeak"
    mean_vmsize="$stats_vmsize"
    mean_vmhwm="$stats_vmhwm"
    mean_vmrss="$stats_vmrss"
    mean_free_sec="$stats_free_sec"

    # Convert units from kB to MB and format to 3 decimal places
    avg_vmpeak_mb=$(convert_kb_to_mb "$mean_vmpeak")
    avg_vmhwm_mb=$(convert_kb_to_mb "$mean_vmhwm")
    avg_vmsize_mb=$(convert_kb_to_mb "$mean_vmsize")
    avg_vmrss_mb=$(convert_kb_to_mb "$mean_vmrss")

    # Add data to final results CSV
    echo "$mimalloc_version,$workers,$object_size,$avg_vmpeak_mb,$avg_vmsize_mb,$avg_vmhwm_mb,$avg_vmrss_mb,$mean_free_sec" >> "$FINAL_RESULTS_FILE"

    # Calculate statistics and add to FINAL_STATS_FILE
    # Prepare values for each Metric
    # avg_VmPeak_MB
    echo "$mimalloc_version,$workers,$object_size,avg_VmPeak_MB,$avg_vmpeak_mb" >> "$FINAL_STATS_FILE"

    # avg_VmHWM_MB
    echo "$mimalloc_version,$workers,$object_size,avg_VmHWM_MB,$avg_vmhwm_mb" >> "$FINAL_STATS_FILE"

    # avg_Free_Sec_M
    echo "$mimalloc_version,$workers,$object_size,avg_Free_Sec_M,$mean_free_sec" >> "$FINAL_STATS_FILE"

    # avg_VmSize_MB
    echo "$mimalloc_version,$workers,$object_size,avg_VmSize_MB,$avg_vmsize_mb" >> "$FINAL_STATS_FILE"

    # avg_VmRSS_MB
    echo "$mimalloc_version,$workers,$object_size,avg_VmRSS_MB,$avg_vmrss_mb" >> "$FINAL_STATS_FILE"

    # Remove compiled test program
    rm -f "$COMPILED_TEST_PROGRAM"

    return 0
}

# Function to generate a new CSV file for each metric
generate_metric_csv() {
    local metric=$1
    local output_csv="$BASE_OUTPUT_DIR/${metric}.csv"

    # Generate header
    # Get library names
    libraries=$(awk -F',' 'NR>1 {print $1}' "$FINAL_RESULTS_FILE" | sort | uniq)

    # Get object sizes and sort in ascending order
    object_sizes=$(awk -F',' 'NR>1 {print $3}' "$FINAL_RESULTS_FILE" | sort -n | uniq)

    # Header row
    echo -n "object_size" > "$output_csv"
    for lib in $libraries; do
        echo -n ",$lib" >> "$output_csv"
    done
    echo "" >> "$output_csv"

    # Determine column number corresponding to the specified metric
    case "$metric" in
        "avg_Free_Sec_M")
            col=8
            ;;
        "avg_VmPeak_MB")
            col=4
            ;;
        "avg_VmHWM_MB")
            col=6
            ;;
        "avg_VmSize_MB")
            col=5
            ;;
        "avg_VmRSS_MB")
            col=7
            ;;
        *)
            echo "Unknown metric: $metric" >&2
            return 1
            ;;
    esac

    # Generate a row for each object size
    for size in $object_sizes; do
        echo -n "$size" >> "$output_csv"
        for lib in $libraries; do
            # Search for the corresponding row and get the value of the specified column
            value=$(awk -F',' -v lib="$lib" -v size="$size" -v col="$col" '
                NR>1 && $1 == lib && $3 == size {print $col}' "$FINAL_RESULTS_FILE")
            if [ -z "$value" ]; then
                echo -n "," >> "$output_csv"
            else
                # Remove leading/trailing spaces from the value and adjust decimal places
                value=$(echo "$value" | xargs)
                # Adjust decimal places as needed (e.g., 3 digits)
                if [[ "$value" =~ \. ]]; then
                    value=$(printf "%.3f" "$value")
                fi
                echo -n ",$value" >> "$output_csv"
            fi
        done
        echo "" >> "$output_csv"
    done

    echo "CSV file generated: $output_csv"
}

# Loop to run all combinations of mimalloc libraries
for mimalloc_dir in "${MIMALLOC_DIRS[@]}"; do
    mimalloc_version=$(basename "$mimalloc_dir")
    echo "Processing mimalloc version: $mimalloc_version"
    for w in "${WORKERS_LIST[@]}"; do
        for s in "${OBJECT_SIZE_LIST[@]}"; do
            attempt=1
            success=0
            while [ $attempt -le $MAX_RETRIES ]; do
                echo "Attempt $attempt for combination mimalloc: $mimalloc_version, workers: $w, object_size: $s"
                run_test_case "$mimalloc_dir" "$mimalloc_version" "$w" "$s"
                if [ $? -eq 0 ]; then
                    success=1
                    break
                else
                    echo "Combination mimalloc: $mimalloc_version, workers: $w, object_size: $s failed on attempt $attempt." >&2
                    attempt=$((attempt + 1))
                    sleep 15  # Wait before retrying
                fi
            done
            if [ $success -ne 1 ]; then
                echo "Combination mimalloc: $mimalloc_version, workers: $w, object_size: $s failed after $MAX_RETRIES attempts." >&2
            fi
            # Proceed to the next combination
            sleep 5
            # Extend the pause time between combinations (2 minutes)
            echo "Cooling down system for 2 minutes..."
            sync
            echo 3 > /proc/sys/vm/drop_caches > /dev/null
            swapoff -a && swapon -a  # Reset swap
            sleep 120
        done
    done
done

echo "All test cases have been completed. Memory usage logs and test outputs are saved in $BASE_OUTPUT_DIR."

# Generate new CSV files from here
echo "Generating new CSV files..."

# List of metrics to generate
metrics=("avg_Free_Sec_M" "avg_VmPeak_MB" "avg_VmHWM_MB" "avg_VmSize_MB" "avg_VmRSS_MB")

for metric in "${metrics[@]}"; do
    generate_metric_csv "$metric"
done

chmod 777 -R "$BASE_OUTPUT_DIR"

echo "All new CSV files have been generated."
