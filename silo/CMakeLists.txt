include(GNUInstallDirs)
include(CMakePackageConfigHelpers)
include(CompileOptions)

file(GLOB YCSB_SILO_SOURCES
        "../common/result.cc"
        "../common/util.cc"
        "result.cc"
        "ycsb_silo.cc"
        "transaction.cc"
        "util.cc"
        )

file(GLOB TPCC_SILO_SOURCES
        "../common/result.cc"
        "../common/util.cc"
        "result.cc"
        "tpcc_silo.cc"
        "transaction.cc"
        "util.cc"
        )

file(GLOB BOMB_SILO_SOURCES
        "../common/result.cc"
        "../common/util.cc"
        "result.cc"
        "bomb_silo.cc"
        "transaction.cc"
        "util.cc"
        )

file(GLOB SBOMB_SILO_SOURCES
        "../common/result.cc"
        "../common/util.cc"
        "result.cc"
        "sbomb_silo.cc"
        "transaction.cc"
        "util.cc"
        )

file(GLOB REPLAY_SOURCES
        "replayTest.cc"
        )

add_executable(ycsb_silo.exe ${YCSB_SILO_SOURCES})
add_executable(tpcc_silo.exe ${TPCC_SILO_SOURCES})
add_executable(bomb_silo.exe ${BOMB_SILO_SOURCES})
add_executable(sbomb_silo.exe ${SBOMB_SILO_SOURCES})
add_executable(replay_test.exe ${REPLAY_SOURCES})


# Convenience targets for experiments: build Silo variants with and without Cicada backoff.
add_executable(silo_with_backoff ${YCSB_SILO_SOURCES})
target_link_libraries(silo_with_backoff
    Boost::filesystem
    gflags::gflags
    ${THIRD_PARTY_DIR}/mimalloc/out/release/libmimalloc.a
    ${THIRD_PARTY_DIR}/masstree/libkohler_masstree_json.a
    Threads::Threads
    )
target_compile_definitions(silo_with_backoff PRIVATE BACK_OFF=1)

add_executable(silo_without_backoff ${YCSB_SILO_SOURCES})
target_link_libraries(silo_without_backoff
    Boost::filesystem
    gflags::gflags
    ${THIRD_PARTY_DIR}/mimalloc/out/release/libmimalloc.a
    ${THIRD_PARTY_DIR}/masstree/libkohler_masstree_json.a
    Threads::Threads
    )
target_compile_definitions(silo_without_backoff PRIVATE BACK_OFF=0)

add_executable(silo_with_TAM ${YCSB_SILO_SOURCES})
target_link_libraries(silo_with_TAM
    Boost::filesystem
    gflags::gflags
    ${THIRD_PARTY_DIR}/mimalloc/out/release/libmimalloc.a
    ${THIRD_PARTY_DIR}/masstree/libkohler_masstree_json.a
    Threads::Threads
    )
target_compile_definitions(silo_with_TAM PRIVATE BACK_OFF=0)

target_link_libraries(ycsb_silo.exe
        Boost::filesystem
        gflags::gflags
        ${THIRD_PARTY_DIR}/mimalloc/out/release/libmimalloc.a
        ${THIRD_PARTY_DIR}/masstree/libkohler_masstree_json.a
        Threads::Threads
        )

target_link_libraries(tpcc_silo.exe
        Boost::filesystem
        gflags::gflags
        ${THIRD_PARTY_DIR}/mimalloc/out/release/libmimalloc.a
        ${THIRD_PARTY_DIR}/masstree/libkohler_masstree_json.a
        Threads::Threads
        )

target_link_libraries(bomb_silo.exe
        Boost::filesystem
        gflags::gflags
        ${THIRD_PARTY_DIR}/mimalloc/out/release/libmimalloc.a
        ${THIRD_PARTY_DIR}/masstree/libkohler_masstree_json.a
        Threads::Threads
        )

target_link_libraries(sbomb_silo.exe
        Boost::filesystem
        gflags::gflags
        ${THIRD_PARTY_DIR}/mimalloc/out/release/libmimalloc.a
        ${THIRD_PARTY_DIR}/masstree/libkohler_masstree_json.a
        Threads::Threads
        )

if (DEFINED ADD_ANALYSIS)
    add_definitions(-DADD_ANALYSIS=${ADD_ANALYSIS})
else ()
    add_definitions(-DADD_ANALYSIS=0)
endif ()

## Configure BACK_OFF per-target instead of globally to avoid macro redefinition
if (DEFINED BACK_OFF)
    target_compile_definitions(ycsb_silo.exe PRIVATE BACK_OFF=${BACK_OFF})
    target_compile_definitions(tpcc_silo.exe PRIVATE BACK_OFF=${BACK_OFF})
    target_compile_definitions(bomb_silo.exe PRIVATE BACK_OFF=${BACK_OFF})
    target_compile_definitions(sbomb_silo.exe PRIVATE BACK_OFF=${BACK_OFF})
else ()
    # default behaviour: existing targets use BACK_OFF=1
    target_compile_definitions(ycsb_silo.exe PRIVATE BACK_OFF=1)
    target_compile_definitions(tpcc_silo.exe PRIVATE BACK_OFF=1)
    target_compile_definitions(bomb_silo.exe PRIVATE BACK_OFF=1)
    target_compile_definitions(sbomb_silo.exe PRIVATE BACK_OFF=1)
endif ()

if (DEFINED KEY_SIZE)
    add_definitions(-DKEY_SIZE=${KEY_SIZE})
else ()
    add_definitions(-DKEY_SIZE=8)
endif ()

if (DEFINED MASSTREE_USE)
    add_definitions(-DMASSTREE_USE=${MASSTREE_USE})
else ()
    add_definitions(-DMASSTREE_USE=1)
endif ()

if (DEFINED NO_WAIT_LOCKING_IN_VALIDATION)
    add_definitions(-DNO_WAIT_LOCKING_IN_VALIDATION=${NO_WAIT_LOCKING_IN_VALIDATION})
else ()
    add_definitions(-DNO_WAIT_LOCKING_IN_VALIDATION=1)
endif ()

if (DEFINED NO_WAIT_OF_TICTOC)
    add_definitions(-DNO_WAIT_OF_TICTOC=${NO_WAIT_OF_TICTOC})
else ()
    add_definitions(-DNO_WAIT_OF_TICTOC=0)
endif ()

if (DEFINED PARTITION_TABLE)
    add_definitions(-DPARTITION_TABLE=${PARTITION_TABLE})
else ()
    add_definitions(-DPARTITION_TABLE=0)
endif ()

if (DEFINED PROCEDURE_SORT)
    add_definitions(-DPROCEDURE_SORT=${PROCEDURE_SORT})
else ()
    add_definitions(-DPROCEDURE_SORT=0)
endif ()

if (DEFINED SLEEP_READ_PHASE)
    add_definitions(-DSLEEP_READ_PHASE=${SLEEP_READ_PHASE})
else ()
    add_definitions(-DSLEEP_READ_PHASE=0)
endif ()

if (DEFINED VAL_SIZE)
    add_definitions(-DVAL_SIZE=${VAL_SIZE})
else ()
    add_definitions(-DVAL_SIZE=4)
endif ()

if (DEFINED WAL)
    add_definitions(-DWAL=${WAL})
else ()
    add_definitions(-DWAL=0)
endif ()

if (DEFINED INSERT_READ_DELAY_MS)
    add_definitions(-DINSERT_READ_DELAY_MS=${INSERT_READ_DELAY_MS})
else ()
    remove_definitions(-DINSERT_READ_DELAY_MS)
endif ()

if (DEFINED INSERT_BATCH_DELAY_MS)
    add_definitions(-DINSERT_BATCH_DELAY_MS=${INSERT_BATCH_DELAY_MS})
else ()
    remove_definitions(-DINSERT_BATCH_DELAY_MS)
endif ()
