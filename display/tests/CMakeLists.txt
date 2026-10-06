# Unit tests: `ctest --test-dir build/display` (or run the binaries directly).
foreach(name tst_sseparser tst_streamfunction tst_voiceclient)
    qt_add_executable(${name} ${name}.cpp)
    target_compile_options(${name} PRIVATE ${HOMEOS_WARNINGS})
    target_link_libraries(${name} PRIVATE homeos-core Qt6::Test)
    add_test(NAME ${name} COMMAND ${name})
    set_tests_properties(${name} PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
endforeach()

# The assistant and the family store in live mode, against a fake Supabase.
qt_add_executable(tst_assistant tst_assistant.cpp
    ../src/models/Assistant.h    ../src/models/Assistant.cpp
    ../src/models/FamilyStore.h  ../src/models/FamilyStore.cpp
    ../src/models/ColorSampler.h ../src/models/ColorSampler.cpp
)
target_compile_options(tst_assistant PRIVATE ${HOMEOS_WARNINGS})
target_link_libraries(tst_assistant PRIVATE homeos-core Qt6::Gui Qt6::Concurrent Qt6::Test)
add_test(NAME tst_assistant COMMAND tst_assistant)
set_tests_properties(tst_assistant PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

# The wake-word card (QuickAnswer.qml) with the real assistant and voice
# client. Its QML and the few components it uses are copied into a module
# directory of their own, since the app's module is built into the binary.
set(quick_qml_dir ${CMAKE_CURRENT_BINARY_DIR}/qml/HomeOS)
set(quick_qmldir "module HomeOS\n")
foreach(file Theme.qml components/Icon.qml components/IconButton.qml components/PillButton.qml
             components/VoiceOrb.qml screens/QuickAnswer.qml)
    configure_file(${PROJECT_SOURCE_DIR}/qml/${file} ${quick_qml_dir}/${file} COPYONLY)
    get_filename_component(type ${file} NAME_WE)
    if(type STREQUAL "Theme")
        string(APPEND quick_qmldir "singleton ")
    endif()
    string(APPEND quick_qmldir "${type} 1.0 ${file}\n")
endforeach()
file(WRITE ${quick_qml_dir}/qmldir "${quick_qmldir}")

qt_add_executable(tst_quickanswer tst_quickanswer.cpp
    ../src/models/Assistant.h    ../src/models/Assistant.cpp
    ../src/models/FamilyStore.h  ../src/models/FamilyStore.cpp
    ../src/models/ColorSampler.h ../src/models/ColorSampler.cpp
)
target_compile_options(tst_quickanswer PRIVATE ${HOMEOS_WARNINGS})
target_compile_definitions(tst_quickanswer PRIVATE HOMEOS_TEST_QML_DIR="${CMAKE_CURRENT_BINARY_DIR}/qml")
target_link_libraries(tst_quickanswer PRIVATE homeos-core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Concurrent Qt6::Test)
add_test(NAME tst_quickanswer COMMAND tst_quickanswer)
set_tests_properties(tst_quickanswer PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
