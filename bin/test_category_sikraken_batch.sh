#!/bin/bash
#
# Script: test_category_sikraken_ecs.sh
# Author: Chris Meudec
# Modified By: Isaiah Andres
# Started: May 2025 (Major update: Oct 2025 for parallel error handling)
# Modified On: Feb 2026
# Description: This is a modified version of an existing script test_category_sikraken.sh to be single threaded so that it may work in an ECS Fargate cluster.
#              Most features and options have been removed by commenting them out as the focus for now is on measuring the performance but have been kept 
#              in case further development may be necessary, so comments explaining other features have been removed until added again.
# The <category>.set file are in sv-benchmarks/c directory or can be user-defined
# Outputs logs files into directory within a shared volume with a docker container /shared/output
# Takes into account possible exclude set for ECA
# For each benchmark: generate tests, upload log to S3 Bucket

# Example: ./SikrakenDevSpace/bin/test_category_sikraken.sh /home/chris/sv-benchmarks/c ECA 8 30 debug --ss=5

clear

echo "Starting Sikraken Batch run..."
mkdir -p "/benchmarks"

S3_BUCKET_NAME="${S3_BUCKET_NAME:-ecs-benchmarks-output}"
S3_BUCKET="${S3_BUCKET_NAME:?S3_BUCKET not set}"
TESTCOMP_S3_BUCKET_NAME="${TESTCOMP_S3_BUCKET_NAME:-testcomp-benchmarks}"
TESTCOMP_BUCKET="${TESTCOMP_S3_BUCKET_NAME:?TESTCOMP_S3_BUCKET_NAME not set}"
CORES="${CORES:-1}"
STACK_SIZE_GB="${STACK_SIZE_GB:-3072}"
CATEGORY="${CATEGORY:-chris}"
MODE="${MODE:-release}"
BUDGET="${BUDGET:-10}"
TIMESTAMP="${TIMESTAMP:?TIMESTAMP environment variable not set}"

#Using Batch environment variables 
TASK_COUNT="${TASK_COUNT:-1}"   
TASK_INDEX="${AWS_BATCH_JOB_ARRAY_INDEX:-0}"   
OUTPUT_SHARED="/output"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" 
SIKRAKEN_INSTALL_DIR="$SCRIPT_DIR/.."
BL='\033[34m'    # blue
YL="\033[38;5;226m"     # yellow
GR='\033[32m'    # green
RD='\033[31m'    # red
NC='\033[0m'     # reset      
script_name=$(basename "$0")

echo "Run all the benchmarks from a TestComp category using SIKRAKEN_INSTALL_DIR=$SIKRAKEN_INSTALL_DIR"

# --- Required arguments ---
path_to_benchmarks="/benchmarks"
category=$CATEGORY
cores=1
budget=$BUDGET
mode=$MODE

# --- Initialize Optional Variables ---
shortcutgen=""
shortcutgen_flag=0
no_testcov=1 #Setting To 1 as no testcov usage yet in ECS version
branch_highlight=0
stack_size_gb=$((STACK_SIZE_GB / 1024))

# --- Process Optional Arguments (Shift and Loop) ---
if [ $# -gt 0 ]; then
    shift 5
    while [ "$#" -gt 0 ]; do
        option="$1"
        case "$option" in
            "-scg")
                shortcutgen=", shortcut_gen"
                shortcutgen_flag=1
                ;;
            "-no_testcov")
                no_testcov=1
                ;;
            "-bh")
                branch_highlight=1
                ;;
            --ss=*)
                # 1. Extract the value after the '=' sign
                stack_size_gb="${1#*=}"
                ;;
            *)
                # Handle unknown options
                echo "Sikraken ERROR from $script_name: Unknown option: $option"
                echo "Usage: $script_name <path_to_benchmarks> <category> <cores> <budget> <mode> [OPTIONS]"
                echo "Options: [-scg] [-no_testcov] [-ss STACK_SIZE]"
                exit 1
                ;;
        esac
        shift
    done
fi

# --- Debug info ---
echo "path_to_benchmarks = $path_to_benchmarks"
echo "category           = $category"
echo "cores              = $cores"
echo "budget             = $budget"
echo "mode               = $mode"
echo "shortcutgen        = $shortcutgen"
echo "no_testcov         = $no_testcov"
echo "task_index         = $TASK_INDEX"
echo "task_count         = $TASK_COUNT"
echo "stack_size         = $stack_size_gb"

check_benchmarks_path(){
    # Check if the path_to_benchmarks exists
    if [ ! -d "$path_to_benchmarks" ]; then
        echo "Sikraken ERROR from $script_name: the passed path to category $path_to_benchmarks does not exist."
        exit 1
    fi
}
check_benchmarks_path

retrieve_category_file(){
    category_file="$category".set   #input file describing the category
    local_category_path="$SIKRAKEN_INSTALL_DIR/categories/"
    # 1. Check local directory (e.g. for non-Test-Comp sets such as chris.set)
    full_path_to_category_file="$local_category_path/$category_file"
    if [ -f "$full_path_to_category_file" ]; then
        echo "Using local category file: $full_path_to_category_file"
    # 2. Check path from argument instead
    elif [ -f "$path_to_benchmarks/$category_file" ]; then
        full_path_to_category_file="$path_to_benchmarks/$category_file"
        echo "Using argument path category file: $full_path_to_category_file"
    # 3. File not found in either location
    else
        echo "Sikraken ERROR from $script_name: The category file '$category_file' was not found in either"
        echo "  - Local Path: $local_category_path"
        echo "  - Argument Path: $path_to_benchmarks"
        exit 1
    fi

    # Define exclusion set for ECA
    exclude_set=""
    if [ $category == "ECA" ]; then
        exclude_set="$SCRIPT_DIR/../ECA-excludes.set"   # local copy, actual exclude file (only category for which there is one) is at https://gitlab.com/sosy-lab/test-comp/bench-defs/-/tree/testcomp25/benchmark-defs/excludes?ref_type=tags 
        if [ ! -f "$exclude_set" ]; then
            echo "Sikraken ERROR from $script_name: Exclusion set $exclude_set does not exist."
            exit 1
        fi
        echo "Sikraken $script_name log: Using the exclude set: "$exclude_set""
    fi

    echo "Sikraken $script_name log: called: $script_name $@"
}
retrieve_category_file

compile_parser(){
    # re-compile the parser in case it changed during development
    $SIKRAKEN_INSTALL_DIR/bin/compile_parser.sh
    if [ $? -ne 0 ]; then
        echo "Sikraken ERROR from $script_name: ERROR: Sikraken parser recompilation failed"
        exit 1
    else
        echo "Sikraken $script_name log: Sikraken parser successfully recompiled"
    fi
}
compile_parser

set_output_directory(){
    output_dir="$OUTPUT_SHARED/$TIMESTAMP"
    echo "The output dir is $output_dir"
    mkdir -p "$output_dir"
}
set_output_directory
# function: generate_tests runs single threaded for ECS
# and terminated with 'return 1' instead of 'exit 1'.
generate_tests() {
    local benchmark="$1"
    local gcc_flag="$2"
    local testcov_data_model="$3"

    # Extract the basename of the file (without the path nor extension)
    local basename=$(basename "$benchmark")
    basename="${basename%.*}"
    local benchmark_output_dir="$output_dir"/"$basename"
    mkdir -p "$benchmark_output_dir"
    local sikraken_log="$benchmark_output_dir/sikraken.log" 
         
    # Generate test inputs
    local benchmark_relative_path=$(realpath --relative-to="$SIKRAKEN_INSTALL_DIR" "$benchmark")
    local sikraken_call="$SIKRAKEN_INSTALL_DIR/bin/sikraken.sh $mode $gcc_flag budget[$budget] --ss=$stack_size_gb $benchmark_relative_path"
    echo -e "${BL}Calling Sikraken using: $sikraken_call${NC}"
    $sikraken_call >> "$sikraken_log" 2>&1
    ret_code=$?
    if [ $ret_code -ne 0 ]; then
        error="Sikraken ERROR from $script_name: error code $ret_code for $basename, Call to Sikraken $sikraken_call failed"
        echo "$error" >> "$sikraken_log"
        echo -e "${RD}$error${NC}"
    else
        echo -e "${GR}Sikraken $script_name log: Test inputs generated for $basename using $sikraken_call${NC}"
    fi

    if [[ "$mode" == "debug" ]]; then   #generate graph of timings
        $SIKRAKEN_INSTALL_DIR/SikrakenDevSpace/bin/helper/create_runtime_graph.sh "$sikraken_log"
    fi

    if (( branch_highlight == 1 )); then    #generate highlighted HTML C code with missing coverage
        $SIKRAKEN_INSTALL_DIR/SikrakenDevSpace/bin/helper/highlight_branches.sh "$sikraken_log" "$SIKRAKEN_INSTALL_DIR/sikraken_output/$basename/$basename.pl" "$benchmark_output_dir/$basename.html"
    else
        echo -e "${YL}Skipping coverage branches highlighting${NC}"
    fi

    if (( no_testcov == 1 )); then
        echo -e "${YL}Skipping TestCov: relying on Sikraken coverage${NC}"
    else
        testcov_call="$SIKRAKEN_INSTALL_DIR/bin/run_testcov.sh"   # program
        testcov_args=( "$benchmark" "$testcov_data_model" )      # args as array
        echo -e "${BL}Calling Testcov using: $testcov_call ${testcov_args[*]}${NC}"

        # run it without eval, preserving arguments and quoting
        "$testcov_call" "${testcov_args[@]}" >"$benchmark_output_dir/testcov_call.log" 2>&1

        echo -e "${GR}Ended TestCov for $basename${NC}"
    fi
}

### MAIN starts here
start_wall_time=$(date +"%Y-%m-%d %H:%M:%S")    # Capture human-readable time and Unix timestamp for start
start_ts=$(date +%s)
mkdir -p "$output_dir/benchmark_files"
category_extracted_benchmarks_files="$output_dir"/benchmark_files/benchmark_files-$TASK_INDEX.txt  #output list of benchmarks for the category
log_file="$output_dir"/category_test_run.log

#printf -v orig_cmd '%q ' "${ORIG_ARGV[@]}"
echo "Command Used to Generate the Category Test run: ${orig_cmd% }" >> "$log_file"
echo "Timestamp: $TIMESTAMP" >> $log_file
echo "Category: $category" >> $log_file
echo "Mode: $mode" >> $log_file
echo "Budget: $budget" >> $log_file
echo "Cores: $cores" >> $log_file
echo "Options: shortcutgen: $shortcutgen_flag, no_testcov: $no_testcov" >> $log_file

retrieve_all_yml_files() {
    mapfile -t PATTERNS < <(
        grep -o '.*\/.*\.yml' "$full_path_to_category_file" | sort
    )
}

retrieve_all_yml_files

download_assigned_benchmarks() {
    TESTCOMP_BUCKET_PREFIX="c"

    mkdir -p "$path_to_benchmarks"

    for i in "${!PATTERNS[@]}"; do
        if (( i % TASK_COUNT != TASK_INDEX )); then
            continue
        fi

        rel_path="${PATTERNS[$i]}"
        dir_name="$(dirname "$rel_path")"
        local_yml_path="$path_to_benchmarks/$rel_path"

        echo "Downloading YAML: $rel_path"

        mkdir -p "$path_to_benchmarks/$dir_name"

        aws s3 cp \
            "s3://$TESTCOMP_BUCKET/$TESTCOMP_BUCKET_PREFIX/$rel_path" \
            "$local_yml_path"

        if [ ! -f "$local_yml_path" ]; then
            echo "Sikraken ERROR: Failed to download $rel_path"
            continue
        fi

        benchmark_file=$(grep "input_files:" "$local_yml_path" \
            | sed -n "s/^[[:space:]]*input_files:[[:space:]]*\(['\"]\?\)\(.*\)\1/\2/p")

        if [ -z "$benchmark_file" ]; then
            echo "Sikraken ERROR: Could not extract input_files from $rel_path"
            continue
        fi

        echo "Downloading benchmark input file: $dir_name/$benchmark_file"

        aws s3 cp \
            "s3://$TESTCOMP_BUCKET/$TESTCOMP_BUCKET_PREFIX/$dir_name/$benchmark_file" \
            "$path_to_benchmarks/$dir_name/$benchmark_file"

        if [ $? -ne 0 ]; then
            echo "Sikraken ERROR: Failed to download benchmark file $benchmark_file"
            continue
        fi
    done
}
download_assigned_benchmarks

run_benchmark(){
    for i in "${!PATTERNS[@]}"; do
        if (( i % TASK_COUNT != TASK_INDEX )); then
            continue
        fi

        pattern_benchmark_directory="${PATTERNS[$i]}"

        for yml_file in "$path_to_benchmarks"/$pattern_benchmark_directory; do
            # Exclude files listed in the exclusion set
            if [ -n "$exclude_set" ] && grep -Fxq "$yml_file" "$exclude_set"; then
                # echo "Sikraken $script_name log: skipping excluded file: $yml_file"
                continue
            fi
            echo "yml_file is $yml_file"
            if [ -f "$yml_file" ]; then
                # Check if the file contains the required property_file line
                if grep -qE "^\s*- property_file: \.\./properties/coverage-branches\.prp$" "$yml_file"; then
                    echo -e "${YL}Sikraken $script_name log: extracting benchmark file from $yml_file${NC}"

                    # Extract the input file (match "input_files: <filename>" for .c or .i files)
                    benchmark=$(grep "input_files:" "$yml_file" | sed -n "s/^[[:space:]]*input_files:[[:space:]]*\(['\"]\?\)\(.*\)\1/\2/p")

                    # Extract the data model
                    data_model=$(grep "data_model:" "$yml_file" | sed -n "s/^[[:space:]]*data_model:[[:space:]]*\(.*\)/\1/p")

                    # Generate GCC flag based on the value of data_model
                    if [ "$data_model" == "ILP32" ]; then
                        gcc_flag="-m32"
                        testcov_data_model="-32"
                    elif [ "$data_model" == "LP64" ]; then
                        gcc_flag="-m64"
                        testcov_data_model="-64"
                    else
                        echo "Sikraken ERROR from $script_name: unsupported data model: $data_model"
                        exit 1
                    fi
                    full_path_benchmark_file="$(dirname "$yml_file")/$benchmark"
                    # write each file in the benchmark category into $category_extracted_benchmarks_files used for table generation
                    echo "$full_path_benchmark_file $testcov_data_model" >> $category_extracted_benchmarks_files
                
                    generate_tests "$full_path_benchmark_file" "$gcc_flag" "$testcov_data_model" 
                fi  # if the .yml file does not contain the correct property, it is silently skipped
            fi
        done #no more *.yml file
    done

    # Capture human-readable time and Unix timestamp for end
    end_wall_time=$(date +"%Y-%m-%d %H:%M:%S")
    end_ts=$(date +%s)
    echo "Sikraken $script_name: Start Wall Time: $start_wall_time"
    echo "Sikraken $script_name: End Wall Time: $end_wall_time"
    duration_seconds=$((end_ts - start_ts))
    duration_hms=$(date -u -d @"$duration_seconds" +"%H:%M:%S")
    echo "Sikraken $script_name: Duration: $duration_hms"
    echo "Duration: $duration_hms" >> $log_file
}

run_benchmark
#generate_table_script="$SIKRAKEN_INSTALL_DIR/SikrakenDevSpace/bin/helper/create_category_test_run_table.sh $output_dir"
#echo "Sikraken $script_name: now calling $generate_table_script"
#$generate_table_script

# update the overall category summary table for all the previous runs
#generate_summary="$SIKRAKEN_INSTALL_DIR/SikrakenDevSpace/bin/helper/view_category_compare.sh ./SikrakenDevSpace/categories/$category/"
#echo "Sikraken $script_name log: now calling $generate_summary"
#$generate_summary

upload_benchmark_to_s3(){
    S3_PREFIX="s3://${S3_BUCKET}/${CATEGORY}/${TIMESTAMP}"
    echo "$S3_PREFIX"
    aws s3 sync "$output_dir" "$S3_PREFIX" --exclude "*.i" --exclude "*.log"

    # Upload .i and .log files with text/plain content-type
    aws s3 sync "$output_dir" "$S3_PREFIX" \
        --exclude "*" \
        --include "*.i" \
        --include "*.log" \
        --content-type text/plain

    echo "Sikraken $script_name log: has ended."
}
upload_benchmark_to_s3