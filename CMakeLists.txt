cmake_minimum_required(VERSION 3.16)
project(cache_coherence_simulator LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(cache_simulator src/cache_simulator.cpp)
target_include_directories(cache_simulator PUBLIC include)

if(MSVC)
    target_compile_options(cache_simulator PRIVATE /W4 /permissive-)
else()
    target_compile_options(cache_simulator PRIVATE -Wall -Wextra -Wpedantic)
endif()

add_executable(cache_sim src/main.cpp)
target_link_libraries(cache_sim PRIVATE cache_simulator)

include(CTest)
if(BUILD_TESTING)
    add_executable(cache_sim_tests tests/cache_simulator_tests.cpp)
    target_link_libraries(cache_sim_tests PRIVATE cache_simulator)
    add_test(NAME cache_simulator_tests COMMAND cache_sim_tests)

    find_program(IVERILOG_EXECUTABLE iverilog)
    find_program(VVP_EXECUTABLE vvp)
    if(IVERILOG_EXECUTABLE AND VVP_EXECUTABLE)
        set(MESI_CONTROLLER_TEST ${CMAKE_CURRENT_BINARY_DIR}/mesi_controller_tb.vvp)
        add_custom_command(
            OUTPUT ${MESI_CONTROLLER_TEST}
            COMMAND ${IVERILOG_EXECUTABLE} -g2012 -Wall -s mesi_controller_tb
                -o ${MESI_CONTROLLER_TEST}
                ${CMAKE_CURRENT_SOURCE_DIR}/rtl/mesi_controller.sv
                ${CMAKE_CURRENT_SOURCE_DIR}/rtl/tb/mesi_controller_tb.sv
            DEPENDS rtl/mesi_controller.sv rtl/tb/mesi_controller_tb.sv
            VERBATIM
        )
        add_custom_target(mesi_controller_rtl_test_image DEPENDS ${MESI_CONTROLLER_TEST})
        add_test(NAME mesi_controller_rtl
            COMMAND ${VVP_EXECUTABLE} ${MESI_CONTROLLER_TEST})

        set(MESI_ARBITER_TEST ${CMAKE_CURRENT_BINARY_DIR}/mesi_bus_arbiter_tb.vvp)
        add_custom_command(
            OUTPUT ${MESI_ARBITER_TEST}
            COMMAND ${IVERILOG_EXECUTABLE} -g2012 -Wall -s mesi_bus_arbiter_tb
                -o ${MESI_ARBITER_TEST}
                ${CMAKE_CURRENT_SOURCE_DIR}/rtl/mesi_bus_arbiter.sv
                ${CMAKE_CURRENT_SOURCE_DIR}/rtl/tb/mesi_bus_arbiter_tb.sv
            DEPENDS rtl/mesi_bus_arbiter.sv rtl/tb/mesi_bus_arbiter_tb.sv
            VERBATIM
        )
        add_custom_target(mesi_bus_arbiter_rtl_test_image DEPENDS ${MESI_ARBITER_TEST})
        add_test(NAME mesi_bus_arbiter_rtl
            COMMAND ${VVP_EXECUTABLE} ${MESI_ARBITER_TEST})

        set(MESI_ARBITER_PARAMETER_TEST_TARGETS)
        foreach(CORE_COUNT IN ITEMS 1 2 3 4)
            set(PARAMETERIZED_ARBITER_TEST
                ${CMAKE_CURRENT_BINARY_DIR}/mesi_bus_arbiter_${CORE_COUNT}core_tb.vvp)
            add_custom_command(
                OUTPUT ${PARAMETERIZED_ARBITER_TEST}
                COMMAND ${IVERILOG_EXECUTABLE} -g2012 -Wall
                    -Pmesi_bus_arbiter_param_tb.CORE_COUNT=${CORE_COUNT}
                    -s mesi_bus_arbiter_param_tb
                    -o ${PARAMETERIZED_ARBITER_TEST}
                    ${CMAKE_CURRENT_SOURCE_DIR}/rtl/mesi_bus_arbiter.sv
                    ${CMAKE_CURRENT_SOURCE_DIR}/rtl/tb/mesi_bus_arbiter_param_tb.sv
                DEPENDS rtl/mesi_bus_arbiter.sv rtl/tb/mesi_bus_arbiter_param_tb.sv
                VERBATIM
            )
            set(PARAMETERIZED_ARBITER_TARGET
                mesi_bus_arbiter_${CORE_COUNT}core_test_image)
            add_custom_target(${PARAMETERIZED_ARBITER_TARGET}
                DEPENDS ${PARAMETERIZED_ARBITER_TEST})
            list(APPEND MESI_ARBITER_PARAMETER_TEST_TARGETS
                ${PARAMETERIZED_ARBITER_TARGET})
            add_test(NAME mesi_bus_arbiter_${CORE_COUNT}core
                COMMAND ${VVP_EXECUTABLE} ${PARAMETERIZED_ARBITER_TEST})
        endforeach()

        set(MESI_FABRIC_PARAMETER_TEST_TARGETS)
        foreach(CORE_COUNT IN ITEMS 1 2 3 4)
            set(PARAMETERIZED_FABRIC_TEST
                ${CMAKE_CURRENT_BINARY_DIR}/mesi_coherence_fabric_${CORE_COUNT}core_tb.vvp)
            add_custom_command(
                OUTPUT ${PARAMETERIZED_FABRIC_TEST}
                COMMAND ${IVERILOG_EXECUTABLE} -g2012 -Wall
                    -Pmesi_coherence_fabric_param_tb.CORE_COUNT=${CORE_COUNT}
                    -s mesi_coherence_fabric_param_tb
                    -o ${PARAMETERIZED_FABRIC_TEST}
                    ${CMAKE_CURRENT_SOURCE_DIR}/rtl/mesi_controller.sv
                    ${CMAKE_CURRENT_SOURCE_DIR}/rtl/mesi_bus_arbiter.sv
                    ${CMAKE_CURRENT_SOURCE_DIR}/rtl/mesi_coherence_fabric.sv
                    ${CMAKE_CURRENT_SOURCE_DIR}/rtl/tb/mesi_coherence_fabric_param_tb.sv
                DEPENDS rtl/mesi_controller.sv rtl/mesi_bus_arbiter.sv
                    rtl/mesi_coherence_fabric.sv
                    rtl/tb/mesi_coherence_fabric_param_tb.sv
                VERBATIM
            )
            set(PARAMETERIZED_FABRIC_TARGET
                mesi_coherence_fabric_${CORE_COUNT}core_test_image)
            add_custom_target(${PARAMETERIZED_FABRIC_TARGET}
                DEPENDS ${PARAMETERIZED_FABRIC_TEST})
            list(APPEND MESI_FABRIC_PARAMETER_TEST_TARGETS
                ${PARAMETERIZED_FABRIC_TARGET})
            add_test(NAME mesi_coherence_fabric_${CORE_COUNT}core
                COMMAND ${VVP_EXECUTABLE} ${PARAMETERIZED_FABRIC_TEST})
        endforeach()

        set(MESI_INTEGRATED_TEST ${CMAKE_CURRENT_BINARY_DIR}/mesi_2core_integrated_tb.vvp)
        add_custom_command(
            OUTPUT ${MESI_INTEGRATED_TEST}
            COMMAND ${IVERILOG_EXECUTABLE} -g2012 -Wall -s mesi_2core_integrated_tb
                -o ${MESI_INTEGRATED_TEST}
                ${CMAKE_CURRENT_SOURCE_DIR}/rtl/mesi_controller.sv
                ${CMAKE_CURRENT_SOURCE_DIR}/rtl/mesi_bus_arbiter.sv
                ${CMAKE_CURRENT_SOURCE_DIR}/rtl/mesi_coherence_fabric.sv
                ${CMAKE_CURRENT_SOURCE_DIR}/rtl/tb/mesi_2core_integrated_tb.sv
            DEPENDS rtl/mesi_controller.sv rtl/mesi_bus_arbiter.sv
                rtl/mesi_coherence_fabric.sv
                rtl/tb/mesi_2core_integrated_tb.sv
            VERBATIM
        )
        add_custom_target(mesi_2core_integrated_rtl_test_image
            DEPENDS ${MESI_INTEGRATED_TEST})
        add_test(NAME mesi_2core_integrated_rtl
            COMMAND ${VVP_EXECUTABLE} ${MESI_INTEGRATED_TEST})
        set(MESI_FABRIC_SERIALIZATION_TEST
            ${CMAKE_CURRENT_BINARY_DIR}/mesi_fabric_completion_serialization_tb.vvp)
        add_custom_command(
            OUTPUT ${MESI_FABRIC_SERIALIZATION_TEST}
            COMMAND ${IVERILOG_EXECUTABLE} -g2012 -Wall
                -s mesi_fabric_completion_serialization_tb
                -o ${MESI_FABRIC_SERIALIZATION_TEST}
                ${CMAKE_CURRENT_SOURCE_DIR}/rtl/mesi_controller.sv
                ${CMAKE_CURRENT_SOURCE_DIR}/rtl/mesi_bus_arbiter.sv
                ${CMAKE_CURRENT_SOURCE_DIR}/rtl/mesi_coherence_fabric.sv
                ${CMAKE_CURRENT_SOURCE_DIR}/rtl/tb/mesi_fabric_completion_serialization_tb.sv
            DEPENDS rtl/mesi_controller.sv rtl/mesi_bus_arbiter.sv
                rtl/mesi_coherence_fabric.sv
                rtl/tb/mesi_fabric_completion_serialization_tb.sv
            VERBATIM
        )
        add_custom_target(mesi_fabric_completion_serialization_test_image
            DEPENDS ${MESI_FABRIC_SERIALIZATION_TEST})
        add_test(NAME mesi_fabric_completion_serialization
            COMMAND ${VVP_EXECUTABLE} ${MESI_FABRIC_SERIALIZATION_TEST})
        set(MESI_CONCURRENT_TEST ${CMAKE_CURRENT_BINARY_DIR}/mesi_2core_concurrent_tb.vvp)
        add_custom_command(
            OUTPUT ${MESI_CONCURRENT_TEST}
            COMMAND ${IVERILOG_EXECUTABLE} -g2012 -Wall -s mesi_2core_concurrent_tb
                -o ${MESI_CONCURRENT_TEST}
                ${CMAKE_CURRENT_SOURCE_DIR}/rtl/mesi_controller.sv
                ${CMAKE_CURRENT_SOURCE_DIR}/rtl/mesi_bus_arbiter.sv
                ${CMAKE_CURRENT_SOURCE_DIR}/rtl/tb/mesi_2core_concurrent_tb.sv
            DEPENDS rtl/mesi_controller.sv rtl/mesi_bus_arbiter.sv
                rtl/tb/mesi_2core_concurrent_tb.sv
            VERBATIM
        )
        add_custom_target(mesi_2core_concurrent_rtl_test_image
            DEPENDS ${MESI_CONCURRENT_TEST})
        add_test(NAME mesi_2core_concurrent_rtl
            COMMAND ${VVP_EXECUTABLE} ${MESI_CONCURRENT_TEST})
        set(MESI_CACHE_SYSTEM_TEST
            ${CMAKE_CURRENT_BINARY_DIR}/mesi_cache_system_tb.vvp)
        add_custom_command(
            OUTPUT ${MESI_CACHE_SYSTEM_TEST}
            COMMAND ${IVERILOG_EXECUTABLE} -g2012 -Wall -s mesi_cache_system_tb
                -o ${MESI_CACHE_SYSTEM_TEST}
                ${CMAKE_CURRENT_SOURCE_DIR}/rtl/mesi_cache_system.sv
                ${CMAKE_CURRENT_SOURCE_DIR}/rtl/tb/mesi_cache_system_tb.sv
            DEPENDS rtl/mesi_cache_system.sv rtl/tb/mesi_cache_system_tb.sv
            VERBATIM
        )
        add_custom_target(mesi_cache_system_rtl_test_image
            DEPENDS ${MESI_CACHE_SYSTEM_TEST})
        add_test(NAME mesi_cache_system_rtl
            COMMAND ${VVP_EXECUTABLE} ${MESI_CACHE_SYSTEM_TEST})
        find_package(Python3 COMPONENTS Interpreter QUIET)
        if(Python3_Interpreter_FOUND AND CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
            add_test(NAME cpp_rtl_cross_model
                COMMAND ${Python3_EXECUTABLE}
                    ${CMAKE_CURRENT_SOURCE_DIR}/tests/compare_cpp_rtl.py
                    --cxx ${CMAKE_CXX_COMPILER}
                    --iverilog ${IVERILOG_EXECUTABLE}
                    --vvp ${VVP_EXECUTABLE})
        endif()
        add_dependencies(cache_sim_tests
            mesi_controller_rtl_test_image
            mesi_bus_arbiter_rtl_test_image
            ${MESI_ARBITER_PARAMETER_TEST_TARGETS}
            ${MESI_FABRIC_PARAMETER_TEST_TARGETS}
            mesi_2core_integrated_rtl_test_image
            mesi_fabric_completion_serialization_test_image
            mesi_2core_concurrent_rtl_test_image
            mesi_cache_system_rtl_test_image)
    else()
        message(STATUS "iverilog/vvp not found; RTL testbenches are available but will not be registered with CTest")
    endif()
endif()
