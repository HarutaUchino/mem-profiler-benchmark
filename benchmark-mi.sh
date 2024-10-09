#!/bin/bash

# Remove set -e to prevent the script from exiting on errors
set -u
set -o pipefail

# Set the maximum number of retries
MAX_RETRIES=3

# Function to display error messages (does not exit the script)
error_exit() {
  echo "Error: $1" >&2
}

# List of mimalloc library directories
MIMALLOC_DIRS=(
  "$HOME/mimalloc-2.1.7/out/rel_1006_1GB"
  "$HOME/mimalloc-2.1.7/out/rel_1006_512MB"
  "$HOME/mimalloc-2.1.7/out/rel_1006_256MB"
  "$HOME/mimalloc-2.1.7/out/rel_1006_128MB"
)

# Test program source file and include directory
TEST_PROGRAM_SRC="../test/xmalloc-mi.c"
MIMALLOC_INCLUDE="$HOME/mimalloc-2.1.7/include"

# List of thread counts and object sizes
WORKERS_LIST=(8) # Add or modify as needed
# OBJECT_SIZE_LIST=(1024 262144 1048576 67108864)
OBJECT_SIZE_LIST=(262144 524288 1048576 2097152 4194304 8388608 67108864)
RUN_TIME=300
RUN_COUNT=5

# Create output directory
TODAY=$(date '+%Y-%m-%d')
BASE_OUTPUT_DIR="../results_mi/$TODAY"
mkdir -p "$BASE_OUTPUT_DIR"

# Define the final results CSV file
FINAL_RESULTS_FILE="$BASE_OUTPUT_DIR/final_results.csv"
# Write the header row to the final results CSV file
echo "mimalloc_version,workers,object_size,avg_VmPeak_kB,avg_VmSize_kB,avg_VmHWM_kB,avg_VmRSS_kB,avg_Free_Sec_M" > "$FINAL_RESULTS_FILE"

# Function to get memory information from process status
get_memory_info() {
  local pid=$1
  local log_file=$2
  # Check if the process directory exists
  if [ -d /proc/$pid ]; then
    # Check if the process status file exists
    if [ -f /proc/$pid/status ]; then
      # Extract memory information from /proc/[PID]/status
      VmPeak=$(awk '/VmPeak:/ {print $2}' /proc/$pid/status 2>/dev/null)
      VmSize=$(awk '/VmSize:/ {print $2}' /proc/$pid/status 2>/dev/null)
      VmHWM=$(awk '/VmHWM:/ {print $2}' /proc/$pid/status 2>/dev/null)
      VmRSS=$(awk '/VmRSS:/ {print $2}' /proc/$pid/status 2>/dev/null)
      Timestamp=$(date '+%Y-%m-%d %H:%M:%S')
      # Write the memory information to the log file
      echo "$Timestamp, $VmPeak, $VmSize, $VmHWM, $VmRSS" >> "$log_file"
    else
      # Log a message if the process has terminated
      echo "Process $pid has terminated." >> "$log_file"
    fi
  else
    # Log a message if the process has terminated
    echo "Process $pid has terminated." >> "$log_file"
  fi
}

# Function to extract the free/sec value from the test output
extract_free_sec() {
  local output_txt=$1
  free_sec=$(grep "free/sec:" "$output_txt" | awk -F'free/sec: ' '{print $2}' | awk '{print $1}')
  # Maintain the "0.xxxx" format
  echo "$free_sec"
}

# Function to compute the average memory usage
compute_average_memory() {
  local average_file=$1
  shift
  local log_files=("$@")

  {
    echo "Metric, VmPeak (kB), VmSize (kB), VmHWM (kB), VmRSS (kB)"
    awk '
        BEGIN {
            FS=","
            OFS=","
            sum_VmPeak=0
            sum_VmSize=0
            sum_VmHWM=0
            sum_VmRSS=0
            count=0
        }
        FNR > 1 {
            sum_VmPeak += $2
            sum_VmSize += $3
            sum_VmHWM += $4
            sum_VmRSS += $5
            count++
        }
        END {
            if (count > 0) {
                avg_VmPeak = sum_VmPeak / count
                avg_VmSize = sum_VmSize / count
                avg_VmHWM = sum_VmHWM / count
                avg_VmRSS = sum_VmRSS / count
                print "Average", avg_VmPeak, avg_VmSize, avg_VmHWM, avg_VmRSS
            }
        }
        ' "${log_files[@]}"
  } > "$average_file"
}

# Function to compute the average free/sec
compute_average_free_sec() {
  local average_file=$1
  shift
  local free_sec_values=("$@")

  {
    echo "Metric, Free_Sec (M)"
    local sum=0
    local count=0
    for value in "${free_sec_values[@]}"; do
      # Process only numeric values
      if [[ "$value" =~ ^[0-9]*\.[0-9]+$ ]]; then
        sum=$(echo "$sum + $value" | bc)
        count=$((count + 1))
      fi
    done

    if [ "$count" -gt 0 ]; then
      avg=$(echo "scale=3; $sum / $count" | bc)
      # Maintain the "0.xxxx" format
      echo "Average_Free_Sec, $avg"
    else
      echo "Average_Free_Sec, N/A"
    fi
  } > "$average_file"
}

# Function to run a test case
run_test_case() {
  local mimalloc_dir=$1
  local mimalloc_version=$2
  local workers=$3
  local object_size=$4

  # Define the output directory for this test case
  OUTPUT_DIR="$BASE_OUTPUT_DIR/mimalloc_$mimalloc_version/w${workers}_s${object_size}"
  mkdir -p "$OUTPUT_DIR"

  # Define the path to the compiled test program
  COMPILED_TEST_PROGRAM="$OUTPUT_DIR/xmalloc-mi"

  # Create the symlink only once
  if [ ! -f "$mimalloc_dir/libmimalloc.so.2" ]; then
    ln -s "libmimalloc.so.2.1" "$mimalloc_dir/libmimalloc.so.2" || {
      echo "Failed to create symlink libmimalloc.so.2 in $mimalloc_dir" >&2
      return 1
    }
  fi

  # Initialize arrays to store free/sec values and memory log file paths
  free_sec_values=()
  memory_log_files=()

  # Flag to ensure compilation is done only once
  COMPILE_SUCCESS=0

  # Loop through the specified number of runs
  for run in $(seq 1 $RUN_COUNT); do
    # Set LD_PRELOAD to the mimalloc library
    unset LD_PRELOAD
    export LD_PRELOAD="$mimalloc_dir/libmimalloc.so.2.1"

    # Compile the test program if not already compiled
    if [ $COMPILE_SUCCESS -eq 0 ]; then
      # Add optimization flags to the test program compilation
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

    # Save the output of ldd
    ldd "$COMPILED_TEST_PROGRAM" > "$OUTPUT_DIR/ldd_output.txt"
    if [ $? -ne 0 ]; then
      echo "ldd failed for $COMPILED_TEST_PROGRAM" >&2
      return 1
    fi

    # Create the run directory
    RUN_DIR="$OUTPUT_DIR/run$run"
    mkdir -p "$RUN_DIR"

    # Define the log file and output text file paths
    LOG_FILE="$RUN_DIR/memory_log_mi.csv"
    OUTPUT_TXT="$RUN_DIR/test_output.txt"

    # Write the header row to the memory log file
    echo "Timestamp, VmPeak (kB), VmSize (kB), VmHWM (kB), VmRSS (kB)" > "$LOG_FILE"

    # Write the ldd output to the output text file
    echo "ldd output:" > "$OUTPUT_TXT"
    cat "$OUTPUT_DIR/ldd_output.txt" >> "$OUTPUT_TXT"

    # Write the test program output to the output text file
    echo "test program output:" >> "$OUTPUT_TXT"

    # Run the test program in the foreground
    "$COMPILED_TEST_PROGRAM" -w "$workers" -t "$RUN_TIME" -s "$object_size" >> "$OUTPUT_TXT" 2>&1 &
    TEST_PID=$!

    # Run memory information collection in a background process
    # However, be careful not to let the background process itself affect performance
    (
      while kill -0 "$TEST_PID" 2>/dev/null; do
        get_memory_info "$TEST_PID" "$LOG_FILE"
        sleep 1
      done
    ) &

    MEMORY_COLLECTOR_PID=$!

    # Wait for the test program to finish
    wait "$TEST_PID"
    TEST_EXIT_STATUS=$?
    # Wait for the memory information collection process to finish
    wait "$MEMORY_COLLECTOR_PID"

    # Check if the test program exited with an error
    if [ $TEST_EXIT_STATUS -ne 0 ]; then
      echo "Test program exited with error for run $run." >&2
      return 1
    fi

    # Add the log file path to the array
    memory_log_files+=("$LOG_FILE")
    # Extract the free/sec value from the output text file
    free_sec=$(extract_free_sec "$OUTPUT_TXT")
    # Add the free/sec value to the array
    free_sec_values+=("$free_sec")

    echo "Run $run completed. Memory usage logged in $LOG_FILE and output saved in $OUTPUT_TXT."

    # Reset LD_PRELOAD
    unset LD_PRELOAD
  done

  # Compute the average memory usage
  AVERAGE_MEMORY_FILE="$OUTPUT_DIR/average_memory_log.csv"
  compute_average_memory "$AVERAGE_MEMORY_FILE" "${memory_log_files[@]}"

  # Compute the average free/sec
  AVERAGE_FREE_SEC_FILE="$OUTPUT_DIR/average_performance.csv"
  compute_average_free_sec "$AVERAGE_FREE_SEC_FILE" "${free_sec_values[@]}"

  echo "Average memory usage saved in $AVERAGE_MEMORY_FILE."
  echo "Average free/sec saved in $AVERAGE_FREE_SEC_FILE."

  # Add data to the final results CSV
  # Extract data from the average memory usage file
  avg_VmPeak=$(awk -F', ' '/Average/ {print $2}' "$AVERAGE_MEMORY_FILE")
  avg_VmSize=$(awk -F', ' '/Average/ {print $3}' "$AVERAGE_MEMORY_FILE")
  avg_VmHWM=$(awk -F', ' '/Average/ {print $4}' "$AVERAGE_MEMORY_FILE")
  avg_VmRSS=$(awk -F', ' '/Average/ {print $5}' "$AVERAGE_MEMORY_FILE")

  # Extract data from the average free/sec file
  avg_Free_Sec=$(awk -F', ' '/Average_Free_Sec/ {print $2}' "$AVERAGE_FREE_SEC_FILE")

  # Add a row to the final results CSV
  echo "$mimalloc_version,$workers,$object_size,$avg_VmPeak,$avg_VmSize,$avg_VmHWM,$avg_VmRSS,$avg_Free_Sec" >> "$FINAL_RESULTS_FILE"

  # Remove the compiled test program
  rm -f "$COMPILED_TEST_PROGRAM"

  return 0
}

# Run all mimalloc libraries and combinations
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
          sleep 5 # Wait before retrying
        fi
      done
      if [ $success -ne 1 ]; then
        echo "Combination mimalloc: $mimalloc_version, workers: $w, object_size: $s failed after $MAX_RETRIES attempts." >&2
      fi
      # Proceed to the next combination
    done
  done
done

echo "All test cases have been completed. Memory usage logs and test outputs are saved in $BASE_OUTPUT_DIR."