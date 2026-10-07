# Unit tests: `ctest --test-dir build/display` (or run the binaries directly).
qt_add_executable(tst_system tst_system.cpp
    ../src/hardware/SystemController.h
    ../src/hardware/SystemController.cpp)
target_include_directories(tst_system PRIVATE ${PROJECT_SOURCE_DIR}/src)
target_compile_options(tst_system PRIVATE ${HOMEOS_WARNINGS})
target_link_libraries(tst_system PRIVATE Qt6::Network Qt6::Test)
add_test(NAME tst_system COMMAND tst_system)
set_tests_properties(tst_system PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

qt_add_executable(tst_display tst_display.cpp
    ../src/hardware/DisplayController.h
    ../src/hardware/DisplayController.cpp)
target_include_directories(tst_display PRIVATE ${PROJECT_SOURCE_DIR}/src)
target_compile_options(tst_display PRIVATE ${HOMEOS_WARNINGS})
target_link_libraries(tst_display PRIVATE Qt6::Test)
add_test(NAME tst_display COMMAND tst_display)
set_tests_properties(tst_display PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

add_test(NAME system_helper COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/system_helper_test.sh)
add_test(NAME kiosk_boot COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/kiosk_boot_test.sh)
add_test(NAME bootscreen COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/bootscreen_test.sh)

foreach(name tst_sseparser tst_streamfunction tst_voiceclient)
    qt_add_executable(${name} ${name}.cpp)
    target_compile_options(${name} PRIVATE ${HOMEOS_WARNINGS})
    target_link_libraries(${name} PRIVATE homeos-core Qt6::Test)
    add_test(NAME ${name} COMMAND ${name})
    set_tests_properties(${name} PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
endforeach()

# The assistant and the family store in live mode, against a fake Supabase
# (and the store's day rollover in demo mode).
qt_add_executable(tst_assistant tst_assistant.cpp
    ../src/models/Assistant.h    ../src/models/Assistant.cpp
    ../src/models/FamilyStore.h  ../src/models/FamilyStore.cpp
    ../src/models/ColorSampler.h ../src/models/ColorSampler.cpp
)
target_compile_options(tst_assistant PRIVATE ${HOMEOS_WARNINGS})
target_link_libraries(tst_assistant PRIVATE homeos-core Qt6::Gui Qt6::Concurrent Qt6::Test)
# The demo data, at the path the app has it (demo mode's day rollover).
qt_add_resources(tst_assistant "demo_data"
    PREFIX /HomeOS
    BASE ${PROJECT_SOURCE_DIR}
    FILES ${PROJECT_SOURCE_DIR}/resources/demo/family.json)
add_test(NAME tst_assistant COMMAND tst_assistant)
set_tests_properties(tst_assistant PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

# QML tests copy the files they use into a HomeOS module directory of their
# own (<dir>/HomeOS), since the app's module is built into the binary.
function(homeos_test_qml_module dir)
    set(qmldir "module HomeOS\n")
    foreach(file ${ARGN})
        configure_file(${PROJECT_SOURCE_DIR}/qml/${file} ${dir}/HomeOS/${file} COPYONLY)
        get_filename_component(type ${file} NAME_WE)
        if(type STREQUAL "Theme")
            string(APPEND qmldir "singleton ")
        endif()
        string(APPEND qmldir "${type} 1.0 ${file}\n")
    endforeach()
    file(WRITE ${dir}/HomeOS/qmldir "${qmldir}")
endfunction()

# The wake-word card (QuickAnswer.qml) with the real assistant and voice
# client.
homeos_test_qml_module(${CMAKE_CURRENT_BINARY_DIR}/qml
    Theme.qml components/Icon.qml components/IconButton.qml components/PillButton.qml
    components/VoiceOrb.qml screens/QuickAnswer.qml)

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

# The wall dialogs' shell (FormDialog.qml) under a Layer, the way Main.qml
# stacks the on-screen keyboard over dialogs; and closing when the display
# goes idle.
homeos_test_qml_module(${CMAKE_CURRENT_BINARY_DIR}/qml-dialogs
    Theme.qml components/PillButton.qml components/FormField.qml components/FocusFlickable.qml
    components/FormDialog.qml components/Layer.qml)
qt_add_executable(tst_dialogs tst_dialogs.cpp)
target_compile_options(tst_dialogs PRIVATE ${HOMEOS_WARNINGS})
target_compile_definitions(tst_dialogs PRIVATE HOMEOS_TEST_QML_DIR="${CMAKE_CURRENT_BINARY_DIR}/qml-dialogs")
target_link_libraries(tst_dialogs PRIVATE Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Test)
add_test(NAME tst_dialogs COMMAND tst_dialogs)
set_tests_properties(tst_dialogs PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

# The calendar's New event dialog (CalendarScreen.qml): the day and time it
# starts on in each view, and its steppers.
homeos_test_qml_module(${CMAKE_CURRENT_BINARY_DIR}/qml-calendar
    Theme.qml components/Icon.qml components/IconButton.qml components/PillButton.qml
    components/Tag.qml components/SegmentedControl.qml components/MemberAvatar.qml
    components/TimeGrid.qml components/MonthGrid.qml components/Toggle.qml
    components/FormField.qml components/FocusFlickable.qml components/FormDialog.qml
    screens/CalendarScreen.qml)
qt_add_executable(tst_calendar tst_calendar.cpp)
target_compile_options(tst_calendar PRIVATE ${HOMEOS_WARNINGS})
target_compile_definitions(tst_calendar PRIVATE HOMEOS_TEST_QML_DIR="${CMAKE_CURRENT_BINARY_DIR}/qml-calendar")
target_link_libraries(tst_calendar PRIVATE Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Test)
add_test(NAME tst_calendar COMMAND tst_calendar)
set_tests_properties(tst_calendar PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

# Media URLs, posters and colors in live mode, against a fake Supabase and
# admin app (FakeServer.h).
qt_add_executable(tst_media tst_media.cpp FakeServer.h
    ../src/models/FamilyStore.h  ../src/models/FamilyStore.cpp
    ../src/models/ColorSampler.h ../src/models/ColorSampler.cpp
)
target_compile_options(tst_media PRIVATE ${HOMEOS_WARNINGS})
target_link_libraries(tst_media PRIVATE homeos-core Qt6::Gui Qt6::Concurrent Qt6::Test)
add_test(NAME tst_media COMMAND tst_media)
set_tests_properties(tst_media PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

# The video screensaver (VideoSaver.qml) with a stand-in Store, from a module
# directory of its own like tst_quickanswer's.
homeos_test_qml_module(${CMAKE_CURRENT_BINARY_DIR}/qml-videosaver
    Theme.qml components/PhotoTile.qml screensaver/VideoSaver.qml)

qt_add_executable(tst_videosaver tst_videosaver.cpp)
target_compile_options(tst_videosaver PRIVATE ${HOMEOS_WARNINGS})
target_compile_definitions(tst_videosaver PRIVATE HOMEOS_TEST_QML_DIR="${CMAKE_CURRENT_BINARY_DIR}/qml-videosaver")
target_link_libraries(tst_videosaver PRIVATE Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Multimedia Qt6::Test)
add_test(NAME tst_videosaver COMMAND tst_videosaver)
set_tests_properties(tst_videosaver PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

# The Games tab: GamesScreen.qml and every game, with the real theme. They are
# copied into a module directory laid out like the app's resources
# (qrc:/HomeOS/...), so the relative paths between them are the app's.
set(games_root ${CMAKE_CURRENT_BINARY_DIR}/games-qml/HomeOS)
set(games_qmldir "module HomeOS\n")
foreach(file qml/Theme.qml qml/components/Icon.qml qml/components/IconButton.qml
             qml/components/PillButton.qml qml/components/Tag.qml qml/components/SegmentedControl.qml)
    configure_file(${PROJECT_SOURCE_DIR}/${file} ${games_root}/${file} COPYONLY)
    get_filename_component(type ${file} NAME_WE)
    if(type STREQUAL "Theme")
        string(APPEND games_qmldir "singleton ")
    endif()
    string(APPEND games_qmldir "${type} 1.0 ${file}\n")
endforeach()
file(WRITE ${games_root}/qmldir "${games_qmldir}")
file(GLOB_RECURSE games_files RELATIVE ${PROJECT_SOURCE_DIR} CONFIGURE_DEPENDS
    ${PROJECT_SOURCE_DIR}/games/* ${PROJECT_SOURCE_DIR}/qml/games/*)
foreach(file ${games_files} qml/screens/GamesScreen.qml)
    configure_file(${PROJECT_SOURCE_DIR}/${file} ${games_root}/${file} COPYONLY)
endforeach()

qt_add_executable(tst_games tst_games.cpp)
target_compile_options(tst_games PRIVATE ${HOMEOS_WARNINGS})
target_compile_definitions(tst_games PRIVATE HOMEOS_GAMES_QML_DIR="${CMAKE_CURRENT_BINARY_DIR}/games-qml")
target_link_libraries(tst_games PRIVATE Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Test)
add_test(NAME tst_games COMMAND tst_games)
set_tests_properties(tst_games PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
