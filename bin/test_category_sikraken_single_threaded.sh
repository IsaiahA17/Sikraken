#!/bin/bash
# Example: ./SikrakenDevSpace/bin/test_category_sikraken.sh /home/chris/sv-benchmarks/c ECA 8 30 debug --ss=5

clear

echo "Starting Sikraken ECS run..."

echo "Waiting for benchmarks to be fully copied..."
#while [ ! -f /shared/benchmarks/.complete ]; do
#    sleep 1
#done
echo "All benchmarks are present."

echo "Benchmarks content in /shared/benchmarks:"
ls /shared/benchmarks

S3_BUCKET_NAME="ecs-benchmarks-output"
S3_BUCKET="${S3_BUCKET_NAME:?S3_BUCKET not set}"
CORES="${CORES:-4}"
STACK_SIZE_GB="${STACK_SIZE_GB:-3}"
CATEGORY="${CATEGORY:-chris}"
MODE="${MODE:-release}"
BUDGET="${BUDGET:-10}"
TIMESTAMP="${TIMESTAMP:-$(date -u +"%Y_%m_%d_%H_%M")}"

TASK_COUNT="${TASK_COUNT:-1}"   
TASK_INDEX="${TASK_INDEX:-0}"   
OUTPUT_SHARED="/shared/output"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" 
SIKRAKEN_INSTALL_DIR="$SCRIPT_DIR/.."
BL='\033[34m'    # blue
YL="\033[38;5;226m"     # yellow
GR='\033[32m'    # green
RD='\033[31m'    # red
NC='\033[0m'     # reset      
script_name=$(basename "$0")

echo "Run all the benchmarks from a TestComp category using SIKRAKEN_INSTALL_DIR=$SIKRAKEN_INSTALL_DIR"

# --- Check minimum args ---
# Allow up to 8 arguments: 5 required + 3 optional (-scg, -no_testcov, -ss VALUE)
#if [ $# -lt 5 ] || [ $# -gt 8 ]; then
#   echo "Sikraken ERROR from $script_name:"
#    echo "Usage: $script_name <path_to_benchmarks> <category> <cores> <budget> <mode> [OPTIONS]"
#    echo "Options: [-scg] [-no_testcov] [--ss=STACK_SIZE] [-bh]"
#    exit 1
#fi

# Save the full original invocation (script + args) before any shift
#ORIG_ARGV=("$0" "$@")

# --- Required arguments ---
path_to_benchmarks="/shared/benchmarks"
category=$CATEGORY
cores=1
budget=$BUDGET
mode=$MODE

# --- Initialize Optional Variables ---
shortcutgen=""
shortcutgen_flag=0
no_testcov=1 #Setting To 1 as no testcov usage yet in ECS version
branch_highlight=0
stack_size_gb=3

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

# Check if the path_to_benchmarks exists
if [ ! -d "$path_to_benchmarks" ]; then
    echo "Sikraken ERROR from $script_name: the passed path to category $path_to_benchmarks does not exist."
    exit 1
fi

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

echo "Sikraken $script_name log: called: "$script_name $@""

# re-compile the parser in case it changed during development
$SIKRAKEN_INSTALL_DIR/bin/compile_parser.sh
if [ $? -ne 0 ]; then
    echo "Sikraken ERROR from $script_name: ERROR: Sikraken parser recompilation failed"
    exit 1
else
    echo "Sikraken $script_name log: Sikraken parser successfully recompiled"
fi

output_dir="$OUTPUT_SHARED/$TIMESTAMP"
echo "The output dir is $output_dir"
mkdir -p "$output_dir"

# function: generate_tests_and_call_testcov runs single threaded for ECS
# and terminated with 'return 1' instead of 'exit 1'.
generate_tests_and_call_testcov() {
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

category_extracted_benchmarks_files="$output_dir"/benchmark_files.txt  #output list of benchmarks for the category
log_file="$output_dir"/category_test_run.log

printf -v orig_cmd '%q ' "${ORIG_ARGV[@]}"
echo "Command Used to Generate the Category Test run: ${orig_cmd% }" >> "$log_file"
echo "Timestamp: $timestamp" >> $log_file
echo "Category: $category" >> $log_file
echo "Mode: $mode" >> $log_file
echo "Budget: $budget" >> $log_file
echo "Cores: $cores" >> $log_file
echo "Options: shortcutgen: $shortcutgen_flag, no_testcov: $no_testcov" >> $log_file

mapfile -t PATTERNS < <(
    grep -o '.*\/.*\.yml' "$full_path_to_category_file" | sort
)

if (( SHARD_INDEX >= SHARD_COUNT )); then
    echo "ERROR: SHARD_INDEX ($SHARD_INDEX) >= SHARD_COUNT ($SHARD_COUNT)"
    exit 1
fi

for i in "${!PATTERNS[@]}"; do
    if (( i % SHARD_COUNT != SHARD_INDEX )); then
        continue
    fi

    pattern_benchmark_directory="${PATTERNS[$i]}"
    echo "Shard $SHARD_INDEX processing pattern: $pattern_benchmark_directory"

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
            
                generate_tests_and_call_testcov "$full_path_benchmark_file" "$gcc_flag" "$testcov_data_model" 
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

#generate_table_script="$SIKRAKEN_INSTALL_DIR/SikrakenDevSpace/bin/helper/create_category_test_run_table.sh $output_dir"
#echo "Sikraken $script_name: now calling $generate_table_script"
#$generate_table_script

# update the overall category summary table for all the previous runs
#generate_summary="$SIKRAKEN_INSTALL_DIR/SikrakenDevSpace/bin/helper/view_category_compare.sh ./SikrakenDevSpace/categories/$category/"
#echo "Sikraken $script_name log: now calling $generate_summary"
#$generate_summary

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