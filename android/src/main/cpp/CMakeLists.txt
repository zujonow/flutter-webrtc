cmake_minimum_required(VERSION 3.22.1)
project("rnnoise_jni")

set(CMAKE_CXX_STANDARD 17)

# Import the pre-compiled Rust static library per ABI
add_library(rnnoise STATIC IMPORTED)
set_target_properties(rnnoise PROPERTIES
    IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/libs/${ANDROID_ABI}/librnnoise.a
)

# Build the JNI bridge shared library
add_library(
    rnnoise_jni
    SHARED
    native-lib.cpp
)

# Link everything together
target_link_libraries(
    rnnoise_jni
    rnnoise
    android
    log
)
