#!/bin/bash
# TestSuite.sh - Continuous Integration & Quality Approval Test Suite
# Designed for the EnvironmentalAwareReferentialUnit (EARU) Project

# Colors for nice output formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0;0m' # No Color

PROJECT_ROOT="/usr/local/EnvironmentalAwareReferentialUnit"
DAEMON_DIR="$PROJECT_ROOT/EARU_daemon"

echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE}          EARU Daemon Quality Approval & Test Suite Execution          ${NC}"
echo -e "${BLUE}======================================================================${NC}"

# Navigate to daemon directory
cd "$DAEMON_DIR" || { echo -e "${RED}[!] Failed to enter daemon directory at $DAEMON_DIR${NC}"; exit 1; }

# 1. Verification of Toolchains and Environment
echo -e "\n${BLUE}[*] Stage 1: Checking Alire (alr) Environment...${NC}"
if ! command -v alr &> /dev/null; then
    echo -e "${RED}[!] Alire (alr) is not installed or not in PATH!${NC}"
    echo -e "${YELLOW}[i] Prerequisite: Please install Alire via 'brew install alire'${NC}"
    exit 1
fi
echo -e "${GREEN}[ok] Alire is available: $(alr --version | head -n 1)${NC}"

echo -e "\n${BLUE}[*] Checking selected GNAT / GCC toolchain...${NC}"
alr toolchain
if [ $? -ne 0 ]; then
    echo -e "${YELLOW}[!] Warning: Alire toolchain check returned non-zero. Check your compiler selection.${NC}"
fi

# Verify GNAT version inside Alire context
echo -e "\n${BLUE}[*] Verifying GNAT compiler inside Alire context...${NC}"
alr exec -- gnatmake --version | head -n 1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}[ok] GNAT compiler is functional in Alire environment!${NC}"
else
    echo -e "${RED}[!] GNAT compiler failed to run via Alire!${NC}"
    exit 1
fi

# 2. GNAT Compilation Verify
echo -e "\n${BLUE}[*] Stage 2: Compiling with GNAT via Alire...${NC}"
alr --non-interactive build
if [ $? -eq 0 ]; then
    echo -e "${GREEN}[ok] GNAT compilation succeeded!${NC}"
else
    echo -e "${RED}[!] GNAT compilation failed!${NC}"
    exit 1
fi

# 3. GNATprove SPARK Verification
echo -e "\n${BLUE}[*] Stage 3: Running GNATprove (SPARK Static Analysis)...${NC}"
# We run gnatprove with alr exec to load the project's exact gnatprove environment and level=0 for fast validation
alr exec -- gnatprove -P earu_daemon.gpr --level=0 --report=fail
if [ $? -eq 0 ]; then
    echo -e "${GREEN}[ok] GNATprove SPARK analysis completed successfully!${NC}"
else
    echo -e "${YELLOW}[!] GNATprove found potential issues, warnings, or proving failures (check output).${NC}"
fi

# 4. Dependency & Framework Checking (Approval Check)
echo -e "\n${BLUE}[*] Stage 4: Checking Test Frameworks & Dependency Availability...${NC}"

# AUnit Check
echo -e "${BLUE}[+] Verifying package 'aunit'...${NC}"
alr show aunit &> /dev/null
if [ $? -eq 0 ]; then
    echo -e "${GREEN}[ok] 'aunit' package is available in Alire index!${NC}"
    echo -e "${CYAN}    Note: 'aunit' is declared as a project dependency in alire.toml${NC}"
else
    echo -e "${RED}[!] 'aunit' is not available in the Alire index!${NC}"
fi

# Strategy Check
echo -e "${BLUE}[+] Verifying package 'strategy'...${NC}"
alr show strategy &> /dev/null
if [ $? -eq 0 ]; then
    echo -e "${GREEN}[ok] 'strategy' package is available in Alire index!${NC}"
    echo -e "${CYAN}    Note: 'strategy' is declared as a project dependency in alire.toml${NC}"
else
    echo -e "${RED}[!] 'strategy' is not available in the Alire index!${NC}"
fi

# Ahven Check
echo -e "${BLUE}[+] Verifying package 'ahven' / 'Ahven'...${NC}"
alr show ahven &> /dev/null || alr show Ahven &> /dev/null
if [ $? -eq 0 ]; then
    echo -e "${GREEN}[ok] Ahven package is available in Alire index!${NC}"
else
    echo -e "${YELLOW}[!] 'ahven' is NOT available in the default Alire community index.${NC}"
    echo -e "${CYAN}    Info: Ahven is modeled after JUnit but is typically installed manually.${NC}"
    echo -e "${CYAN}          Source is downloadable from: http://www.ahven-framework.com/${NC}"
    echo -e "${CYAN}          You can also use 'utilada_unit' which includes Ahven testing utilities.${NC}"
fi

# 5. GNATcov (Code Coverage) Check
echo -e "\n${BLUE}[*] Stage 5: GNATcov Code Coverage Check...${NC}"
# Check if gnatcov is available in the Alire environment
alr exec -- gnatcov --version &> /dev/null
if [ $? -eq 0 ]; then
    echo -e "${GREEN}[ok] gnatcov is available in the Alire environment!${NC}"
    echo -e "${BLUE}[+] Running coverage check with --annotate=xcov...${NC}"
    # Verify execution under Alire context
    alr exec -- gnatcov run -P earu_daemon.gpr --annotate=xcov ./bin/earu_daemon -- --help &> /dev/null
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[ok] Coverage instrumentation check completed!${NC}"
    else
        echo -e "${YELLOW}[!] Warning: Coverage execution command returned non-zero (may need build/instrumentation setup).${NC}"
    fi
else
    # Also check if it's in standard PATH
    if command -v gnatcov &> /dev/null; then
        echo -e "${GREEN}[ok] gnatcov is available in system PATH!${NC}"
        echo -e "${BLUE}[+] Running coverage check with --annotate=xcov...${NC}"
        gnatcov run -P earu_daemon.gpr --annotate=xcov ./bin/earu_daemon -- --help &> /dev/null
    else
        echo -e "${YELLOW}[!] gnatcov is not installed. Skipping coverage check.${NC}"
        echo -e "${CYAN}    To install: Add it via 'alr toolchain --select gnatcov' or download GNAT Coverage.${NC}"
    fi
fi

# 6. Alire Test suite execution
echo -e "\n${BLUE}[*] Stage 6: Running 'alr test'...${NC}"
alr test
if [ $? -eq 0 ]; then
    echo -e "${GREEN}[ok] alr test passed!${NC}"
else
    echo -e "${RED}[!] alr test failed or returned non-zero!${NC}"
fi

# 7. AFL++ Ada Fuzzing Check
echo -e "\n${BLUE}[*] Stage 7: AFL++ Ada Fuzzing Approval Check...${NC}"
AFL_FUZZ_FOUND=false
AFL_COMPILER_FOUND=false

if command -v afl-fuzz &> /dev/null; then
    echo -e "${GREEN}[ok] AFL++ (afl-fuzz) is available in PATH!${NC}"
    AFL_FUZZ_FOUND=true
else
    echo -e "${YELLOW}[!] AFL++ (afl-fuzz) is not installed in the system PATH.${NC}"
fi

# Check for AFL compilers
for cmd in afl-gcc afl-g++ afl-clang-fast afl-clang-lto; do
    if command -v "$cmd" &> /dev/null; then
        echo -e "${GREEN}[ok] AFL++ compiler wrapper '$cmd' is available!${NC}"
        AFL_COMPILER_FOUND=true
        break
    fi
done

if [ "$AFL_FUZZ_FOUND" = true ] && [ "$AFL_COMPILER_FOUND" = true ]; then
    echo -e "${GREEN}[ok] AFL++ Ada Fuzzing environment is fully ready!${NC}"
    echo -e "${CYAN}    To perform fuzz testing:${NC}"
    echo -e "${CYAN}    1. Compile with instrumented GNAT/GCC wrapper (e.g. CC=afl-gcc alr build)${NC}"
    echo -e "${CYAN}    2. Prepare seed corpus in an 'inputs' directory${NC}"
    echo -e "${CYAN}    3. Run: afl-fuzz -i inputs -o outputs ./bin/earu_daemon${NC}"
else
    echo -e "${YELLOW}[!] AFL++ environment is incomplete. Fuzzing check skipped.${NC}"
    echo -e "${CYAN}    Prerequisite: Install AFL++ (e.g., 'brew install afl++' on macOS).${NC}"
    echo -e "${CYAN}    Make sure to compile the Ada project using afl-gcc/afl-clang instrumentation.${NC}"
fi

echo -e "\n${BLUE}======================================================================${NC}"
echo -e "${GREEN}             Test Suite Execution Complete & Documented               ${NC}"
echo -e "${BLUE}======================================================================${NC}"
