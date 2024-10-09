# mem-profiler-benchmark
## mimalloc Performance Benchmarking Script

This repository contains a Bash script for accurately benchmarking the performance of the mimalloc memory allocator in a multi-threaded environment. The script goes beyond simply measuring memory usage within the test program itself, instead leveraging OS-level process information for a more comprehensive and precise evaluation. This script utilizes the xmalloc-test benchmark program, originally developed by Daan Leijen and available at https://github.com/daanx/mimalloc-bench/tree/master/bench/xmalloc-test, to stress-test the memory allocator and generate realistic memory usage patterns.

### Motivation

Accurately assessing memory allocator performance requires a holistic view of memory usage, considering factors that might not be directly visible within the test program. Traditional approaches of measuring memory consumption solely within the test program can be misleading due to several reasons:

* **Copy-on-Write (COW):** Modern operating systems often employ COW, a memory management technique that delays actual memory allocation until a write operation occurs. This can lead to underestimation of memory usage if measured only within the test program.
* **Measurement Overhead:**  Adding memory measurement code directly into the test program introduces overhead, potentially skewing performance results, especially in multi-threaded scenarios where measurement threads compete with worker threads.

This script addresses these limitations by monitoring memory usage at the OS level, providing a more accurate representation of the memory allocator's behavior.

### Features

* **Multiple mimalloc Configurations:** Benchmarks different builds of mimalloc, allowing for comparison of performance across various configurations (e.g., different huge page sizes).
* **Variable Test Parameters:**  Allows customization of the number of worker threads, object sizes, test duration, and the number of test runs.
* **OS-Level Memory Usage Tracking:**  Collects memory usage data (VmPeak, VmSize, VmHWM, VmRSS) directly from the `/proc` filesystem, capturing the actual memory footprint of the test program as seen by the operating system.
* **Performance Measurement:**  Calculates and reports the average "free/sec" rate, indicating the efficiency of memory deallocation.
* **Error Handling and Retries:**  Includes error handling mechanisms and retries for failed test runs, ensuring robustness.
* **Organized Output:**  Generates well-structured output directories for each test configuration, containing log files, test outputs, and average results.
* **Final Results Summary:**  Creates a final CSV file (`final_results.csv`) summarizing the average memory usage and performance metrics for all tested configurations.

### Script Flowchart

```mermaid
graph TD
    A[Start] --> B{Define mimalloc directories, test parameters}
    B --> C{Create output directory}
    C --> D{Loop through mimalloc versions}
    D --> E{Loop through worker thread counts}
    E --> F{Loop through object sizes}
    F --> G{Run test case}
    G --> H{Compile test program (if not already compiled)}
    H --> I{Set LD_PRELOAD to mimalloc library}
    I --> J{Run test program for specified duration and collect memory usage data from /proc}
    J --> K{Reset LD_PRELOAD}
    K --> L{Compute average memory usage and free/sec}
    L --> M{Save results to CSV files}
    M --> F
    F --> E
    E --> D
    D --> N{End}
```

### Requirements

* **Bash:** The script requires Bash to be installed on your system.
* **mimalloc:** You need to have mimalloc built with the desired configurations. The script assumes the mimalloc libraries are located in specific directories (see `MIMALLOC_DIRS` in the script).
* **gcc:** The script uses `gcc` to compile the test program.
* **awk, grep, bc:** These command-line utilities are used for data processing and calculations.

### Usage

1. **Clone the repository:**
   ```bash
   git clone https://github.com/HarutaUchino/mem-profiler-benchmark.git
   ```

2. **Modify the script:**
   * Update the `MIMALLOC_DIRS` variable with the paths to your mimalloc build directories.
   * Adjust the `TEST_PROGRAM_SRC`, `MIMALLOC_INCLUDE`, `WORKERS_LIST`, `OBJECT_SIZE_LIST`, `RUN_TIME`, and `RUN_COUNT` variables according to your testing requirements.

3. **Run the script:**
   ```bash
   bash benchmark-mi.sh
   ```

### Output

The script will create a directory structure under `../results_mi/$TODAY` (where `$TODAY` is the current date) to store the results. Each mimalloc version, worker thread count, and object size combination will have its own subdirectory containing:

* `memory_log_mi.csv`: Raw memory usage data collected during the test runs.
* `test_output.txt`: Output from the test program and `ldd` command.
* `average_memory_log.csv`: Average memory usage metrics.
* `average_performance.csv`: Average free/sec rate.

Additionally, a final CSV file (`final_results.csv`) will be created in the `BASE_OUTPUT_DIR` summarizing the average results for all tested configurations.
