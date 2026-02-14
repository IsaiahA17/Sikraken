#!/bin/bash
#
# Script: sikraken.sh
# Author: Chris Meudec
# Date: Nov 2025
# Description: Wrapper for Sikraken symbolic execution tool from C code.
# Example: ./bin/sikraken.sh release budget[3] --ss=1 SampleCode/simple_if.c

start_time=$(date +%s.%1N)

# clear # don't: this breaks CI because it requires a TERMINAL environment, which does not exist in CI mode
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SIKRAKEN_INSTALL_DIR="$SCRIPT_DIR/.."
VERSION_FILE="$SIKRAKEN_INSTALL_DIR/bin/version.txt"

# --- Defaults ---
debug_mode="debug"
data_model="-m32"
stack_size_value="$((3 * 953))M" # default 3 GB converted to MiB
algo=""
rel_path_c_file=""
RD='\033[31m'
YL='\033[33m'    # yellow
NC='\033[0m'


# --- HELP FUNCTION ---
show_help() {
    echo "Usage: ./sikraken.sh <mode> <algorithm> [data_model] [stack_size] <c_file>"
    echo ""
    echo "Arguments:"
    echo "  <mode>           : debug (default) or release (only affects the test generation)."
    echo "  <algorithm>      : budget[seconds] (e.g., budget[900]) or regression[restarts,tries] (e.g., regression[1,100])."
    echo "  [data_model]     : -m32 (default) or -m64."
    echo "  [stack_size]     : --ss=STACK_SIZE (Stack size in decimal GB, defaults to 3GB)."
    echo "  <c_file>         : Relative path to the C source file (e.g., SampleCode/simple_if.c)."
    echo ""
    echo "Example: ./bin/sikraken.sh release budget[1] --ss=1 SampleCode/simple_if.c"
}

# --- Version and Help Checks ---
if [ "$1" == "-v" ]; then
    if [[ -f "$VERSION_FILE" ]]; then
        head -n 1 "$VERSION_FILE"
        exit 0
    else
        echo -e "${RD}Error: $VERSION_FILE not found.${NC}"
        exit 1
    fi
elif [ "$1" == "--help" ]; then
    show_help
    exit 0
fi

version=$(head -n 1 "$VERSION_FILE" 2>/dev/null)
echo "Sikraken version: $version"
echo "Invoked with command: $0 $@"
testcomp_flag=0
# --- Parse all arguments except last ---
while [[ $# -gt 1 ]]; do
    case "$1" in
        debug|release)
            debug_mode="$1"
            ;;
        budget*|regression*)
            # Capture the full algorithm string, normalizing delimiters
            algo="${1//[/\(}"
            algo="${algo//]/\)}"
            ;;
        -m32|-m64)
            data_model="$1"
            ;;
        --ss=*)
            # 1. Extract the value after the '=' sign
            stack_size_gb="${1#*=}"
            
            # 2. Validation
            if [[ -z "$stack_size_gb" || ! "$stack_size_gb" =~ ^[0-9]+$ || "$stack_size_gb" -le 0 ]]; then
                echo -e "${RD}Sikraken ERROR: STACK_SIZE for --ss must be a positive integer (GB). Value found: $stack_size_gb${NC}"
                exit 1
            fi
            
            # 3. Calculate and set the final value in MiB
            stack_size_value="$(( stack_size_gb * 953 ))M"
            ;;
        --testcomp) 
            testcomp_flag=1
            ;;
        *)
            echo -e "${RD}Sikraken ERROR: Unknown argument: $1${NC}"
            show_help
            exit 1
            ;;
    esac
    shift
done
local_control_stack_size="953M"     #that's in MiB so about 1000MB

# --- Last argument must be C source path ---
rel_path_c_file="$1"
if [[ ! -f "$rel_path_c_file" ]]; then
    echo -e "${RD}Sikraken ERROR: C source file '$rel_path_c_file' not found.${NC}"
    show_help
    exit 1
fi

# -------------------------------------------------------------
# --- SPECIAL CASE OVERRIDE LOGIC ---
# -------------------------------------------------------------
if [ "$testcomp_flag" -eq 1 ]; then
    echo "Sikraken WARNING: --testcomp option detected. Overwriting settings for TestComp run."
    #debug_mode="debug"                 # for pre-runs to get all the debug messages
    #algo="budget(800)"                 # for pre-runs to get the full stats at the end of Sikraken run 
    #stack_size_value="$((2 * 953))M"   # for pre-runs so as not to hit the limit of 3 GB
    debug_mode="release"                # for Test-Comp final-run : less time wasted writing out messages
    algo="budget(900)"                  # for Test-Comp final-run : to use up all the time available
    #stack_size_value="2382M"
    stack_size_value="2859M"           # in MiB 1 GB ==  953 MiB for Test-Comp final-run : high enough GB to be of benefit, but below competition threshold of 15 GB to ensure Sikraken does not get killed
fi
# -------------------------------------------------------------

echo "SIKRAKEN_INSTALL_DIR: $SIKRAKEN_INSTALL_DIR"
echo "Mode: $debug_mode"
echo "Algorithm: $algo"
echo "Data model: $data_model"
echo "Stack size: $stack_size_value"
echo "C file: $rel_path_c_file"

full_path_c_file="$SIKRAKEN_INSTALL_DIR/$rel_path_c_file"    #e.g. /home/chris/Sikraken/SampleCode/atry_bitwise.c or .i

file_name_no_ext="${rel_path_c_file%.*}"
file_name_no_ext=$(basename "$file_name_no_ext")

call_parser="$SIKRAKEN_INSTALL_DIR/bin/call_parser.sh $data_model $rel_path_c_file"
echo "Sikraken from $0 says: $call_parser"
$call_parser
ret_code=$?
if [ $ret_code -ne 0 ]; then
    echo "Sikraken ERROR from $0: error code $ret_code, parser failed on: $call_parser"
    exit $ret_code
fi

echo "Sikraken from $0 Successfully preprocessed $rel_path_c_file and ran sikraken_parser."
if [[ $algo =~ ^budget\([0-9]+\)$ ]]; then
  budget="${algo//[!0-9]/}"
  echo "Sikraken from $0 says: Please wait $budget seconds for Sikraken to complete"
else
  budget=900
  echo "Sikraken from $0 says: Please wait for Sikraken to complete its $algo search strategy" 
fi

# Call the symbolic executor via ECLiPSe
eclipse_call="$SIKRAKEN_INSTALL_DIR/eclipse/bin/x86_64_linux/eclipse -f $SIKRAKEN_INSTALL_DIR/SymbolicExecutor/se_main.pl -e \"se_main(['$SIKRAKEN_INSTALL_DIR', '${SIKRAKEN_INSTALL_DIR}/${rel_path_c_file}', '$file_name_no_ext', main, testcomp, $algo])\" -g $stack_size_value -l $local_control_stack_size -- -$debug_mode $data_model"
echo "Calling Sikraken using: $eclipse_call"

end_time=$(date +%s.%1N)

cpu_spent=$(awk -v start="$start_time" -v end="$end_time" 'BEGIN {
    diff = end - start;
    if (diff <= 0) print 1;
    else print int(diff + 0.999);
}')

# Optional: if you still want the raw decimal for your debug echo:
cpu_spent_raw=$(awk -v start="$start_time" -v end="$end_time" 'BEGIN { print end - start }')

echo "Sikraken: Preprocessing used ${cpu_spent_raw}s (Rounded up to ${cpu_spent}s for safety)"

# Add wall-clock timeout with safety margin (20% extra to allow for CPU limit to trigger first)
# to end then kill processes tha tjust hang without reaching cpu limit
wall_timeout=$((budget + budget / 5))

budget=$((budget-cpu_spent))
#3 seconds is the minimum, to get stats info, prlimit only take integers
if [ "$budget" -lt 3 ]; then
    budget=3
fi
echo "Remaining budget is $budget"
dump_time=$((budget - 1))
# Run with both CPU limit and wall-clock timeout
# 2> >(head -c 100K >&2) limits the messages to stderr (2>) to 100KB (trap '' PIPE tells bash to ignore the SIGPIPE (141) signal and carry on)
timeout --kill-after=5 "${wall_timeout}" prlimit --cpu="${dump_time}:${budget}" bash -lc "trap '' PIPE; $eclipse_call" 2> >(head -c 100K >&2)
 
ret_code=$?
if [ $ret_code -eq 124 ]; then
    echo -e "${RD}Sikraken ERROR: Process hung and exceeded wall-clock timeout of ${wall_timeout}s without consuming CPU time.${NC}"
    echo -e "${RD}This likely indicates a hang condition (deadlock, infinite wait, or I/O block).${NC}"
    exit 124
elif [ $ret_code -eq 137 ]; then  #sigkill
    echo "Like tears in rain..."
    exit 0
elif [ $ret_code -ne 0 ]; then
    echo "Sikraken ERROR from $0: error code $ret_code, call to ECLiPSe failed on: $eclipse_call"
    exit $ret_code
else
    echo "Sikraken from $0 generated test inputs for $file_name_no_ext in $SIKRAKEN_INSTALL_DIR/sikraken_output/$file_name_no_ext/"
    echo "Sikraken from $0 says, now run: ./bin/run_testcov.sh $rel_path_c_file $testcov_data_model"
    exit 0
fi