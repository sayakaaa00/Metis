ccbench_add_protocol(silo
  SOURCES   transaction.cc util.cc
  WORKLOADS ycsb tpcc bomb sbomb
  OPTIONS
    NO_WAIT_LOCKING_IN_VALIDATION=${CCBENCH_NO_WAIT_LOCKING_IN_VALIDATION}
    NO_WAIT_OF_TICTOC=${CCBENCH_NO_WAIT_OF_TICTOC}
    PARTITION_TABLE=${CCBENCH_PARTITION_TABLE}
    PROCEDURE_SORT=${CCBENCH_PROCEDURE_SORT}
    SLEEP_READ_PHASE=${CCBENCH_SLEEP_READ_PHASE}
    WAL=${CCBENCH_WAL}
    INSERT_READ_DELAY_MS=${CCBENCH_INSERT_READ_DELAY_MS}
    INSERT_BATCH_DELAY_MS=${CCBENCH_INSERT_BATCH_DELAY_MS}
)

# Backward-compatible research binaries. They use the same current Silo
# implementation and common runner as the standard targets; only BACK_OFF and
# the adaptive-variant pinning policy differ. Keep the historical output path
# so existing experiment scripts continue to work unchanged.
function(add_silo_research_variant target source backoff)
  add_executable(${target} ${source} transaction.cc util.cc)
  target_link_libraries(${target} PRIVATE
    ccbench_common ccbench::masstree ccbench::mimalloc)

  get_target_property(_defs ycsb_silo.exe COMPILE_DEFINITIONS)
  list(FILTER _defs EXCLUDE REGEX "^BACK_OFF=")
  list(APPEND _defs BACK_OFF=${backoff} ADAPTIVE_VARIANT=1)
  target_compile_definitions(${target} PRIVATE ${_defs})
  set_compile_options(${target})
  set_target_properties(${target} PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/silo")
endfunction()

add_silo_research_variant(silo_with_TAM ycsb_silo.cc 0)
add_silo_research_variant(ycsb_metis_paper ycsb_silo.cc 0)
add_silo_research_variant(tpcc_with_TAM tpcc_silo.cc 0)
add_silo_research_variant(tpcc_metis_paper tpcc_silo.cc 0)
add_silo_research_variant(silo_with_backoff ycsb_silo.cc 1)
add_silo_research_variant(silo_without_backoff ycsb_silo.cc 0)

# Standalone replay test — not parameterized by workload. It still needs
# the universal -DVAL_SIZE etc. that ccbench_add_protocol applies to the
# workload binaries, so reuse the same helper to assemble them.
ccbench_universal_definitions(_universal_defs)
add_executable(replay_test.exe replayTest.cc)
target_link_libraries(replay_test.exe PRIVATE
  ccbench_common ccbench::masstree ccbench::mimalloc)
target_compile_definitions(replay_test.exe PRIVATE ${_universal_defs})
# Same -Wall -Wextra -Werror as the ccbench_add_protocol() binaries (#43).
set_compile_options(replay_test.exe)

if(CCBENCH_BUILD_SILO_TESTS)
  add_executable(silo_regression_test
    test/transaction_test.cc transaction.cc util.cc)
  target_link_libraries(silo_regression_test PRIVATE
    ccbench_common ccbench::masstree ccbench::mimalloc GTest::gtest_main)
  # Keep protocol switches and Result's layout identical to the workload target.
  get_target_property(_silo_test_defs tpcc_silo.exe COMPILE_DEFINITIONS)
  target_compile_definitions(silo_regression_test PRIVATE ${_silo_test_defs})
  set_compile_options(silo_regression_test)
  add_test(NAME silo_regression_test COMMAND silo_regression_test)
  # The old read protocol spins forever on these deliberately pending INSERTs.
  set_tests_properties(silo_regression_test PROPERTIES TIMEOUT 20)
endif()
