compiler=${1:-clang++}
# Go up one directory from 'build' to 'bitcoin'
pushd . || exit

# Remove the old build directory to ensure a clean slate
# rm -rf build || true

# Create a new build directory
mkdir -p build

# Change into the new build directory
pushd ./build || exit

if command -v brew &> /dev/null
then
    CC=$(brew --prefix llvm)/bin/clang CXX=$(brew --prefix llvm)/bin/clang++
fi

# Run CMake, explicitly setting the C++ standard to 20
# We'll also explicitly set the C++ compiler to clang++ (common on macOS)
# If you prefer g++, replace 'clang++' with 'g++'
cmake -DCMAKE_CXX_STANDARD=20 -DCMAKE_CXX_COMPILER=$compiler -S ../

# Now, try to build again
make
