cmake_minimum_required(VERSION 3.21)
project(homeos-display VERSION 0.2.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 6.4 REQUIRED COMPONENTS Core Gui Network Qml Quick Concurrent Multimedia WebSockets ShaderTools)
qt_standard_project_setup()
# Qt 6.8+ (Raspberry Pi OS / Debian Trixie) warns unless this is set: give each
# QML subfolder its own qmldir. Older Qt (6.4 on Ubuntu 24.04) doesn't know it.
if(QT_KNOWN_POLICY_QTP0004)
    qt_policy(SET QTP0004 NEW)
endif()

option(HOMEOS_BUILD_TESTS "Build the display's unit tests" ON)

if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    set(HOMEOS_WARNINGS -Wall -Wextra)
endif()

# Networking, streaming and voice plumbing: shared by the app and the tests.
add_library(homeos-core STATIC
    src/backend/SupabaseClient.h   src/backend/SupabaseClient.cpp
    src/backend/SseParser.h        src/backend/SseParser.cpp
    src/models/ChatModel.h         src/models/ChatModel.cpp
    src/voice/VoiceClient.h        src/voice/VoiceClient.cpp
)
target_include_directories(homeos-core PUBLIC src)
target_compile_options(homeos-core PRIVATE ${HOMEOS_WARNINGS})
target_link_libraries(homeos-core PUBLIC Qt6::Core Qt6::Network Qt6::WebSockets)

qt_add_executable(homeos-display
    src/main.cpp
    src/models/FamilyStore.h       src/models/FamilyStore.cpp
    src/models/Assistant.h         src/models/Assistant.cpp
    src/models/ColorSampler.h      src/models/ColorSampler.cpp
    src/hardware/DisplayController.h src/hardware/DisplayController.cpp
    src/hardware/SystemController.h src/hardware/SystemController.cpp
)

target_include_directories(homeos-display PRIVATE src)
target_compile_options(homeos-display PRIVATE ${HOMEOS_WARNINGS})
target_compile_definitions(homeos-display PRIVATE HOMEOS_VERSION="${PROJECT_VERSION}")

set_source_files_properties(qml/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

# Open-source games kept as their authors wrote them (display/games/README.md).
# GamesScreen.qml loads them from the resources when one is opened.
file(GLOB_RECURSE homeos_vendored_games RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} CONFIGURE_DEPENDS
    games/samegame/*.qml games/samegame/*.js games/samegame/qmldir games/samegame/*.png
    games/maroon/*.qml games/maroon/*.js games/maroon/*.png games/maroon/*.wav)

qt_add_qml_module(homeos-display
    URI HomeOS
    VERSION 1.0
    RESOURCE_PREFIX /
    QML_FILES
        qml/Main.qml
        qml/Theme.qml
        qml/components/Card.qml
        qml/components/NavRail.qml
        qml/components/MemberAvatar.qml
        qml/components/PillButton.qml
        qml/components/PhotoTile.qml
        qml/components/Icon.qml
        qml/components/IconButton.qml
        qml/components/Glow.qml
        qml/components/GradientTile.qml
        qml/components/Tag.qml
        qml/components/SegmentedControl.qml
        qml/components/TimeGrid.qml
        qml/components/MonthGrid.qml
        qml/components/Page.qml
        qml/components/AnimatedNumber.qml
        qml/components/VideoView.qml
        qml/components/Toggle.qml
        qml/components/VoiceOrb.qml
        qml/components/FormDialog.qml
        qml/components/FormField.qml
        qml/screens/HomeScreen.qml
        qml/screens/CalendarScreen.qml
        qml/screens/TasksScreen.qml
        qml/screens/RewardsScreen.qml
        qml/screens/MediaScreen.qml
        qml/screens/MediaViewer.qml
        qml/screens/PlannerScreen.qml
        qml/screensaver/ScreenSaver.qml
        qml/screensaver/SlideshowSaver.qml
        qml/screensaver/CollageSaver.qml
        qml/screensaver/VideoSaver.qml
        qml/screensaver/SmartFrameSaver.qml
        qml/screensaver/MemoriesSaver.qml
        qml/screensaver/ClockSaver.qml
        qml/screensaver/TodaySaver.qml
        qml/screensaver/Picks.js
        qml/screensaver/ScreenSaverOptions.qml
        qml/screensaver/ScreenSaverPicker.qml
        qml/screens/PairingScreen.qml
        qml/screens/AssistantPanel.qml
        qml/screens/QuickAnswer.qml
        qml/screens/SettingsSheet.qml
        qml/screens/GamesScreen.qml
        qml/games/Game2048.qml
        qml/games/TrafficJam.qml
        qml/games/TicTacToe.qml
        games/2048/game.js
        games/traffic/rush.js
        games/traffic/puzzles.js
    RESOURCES
        resources/demo/family.json
        qml/components/KeyboardPanel.qml
        ${homeos_vendored_games}
)

# ShaderEffect fragment shaders, baked to .qsb at build time (qrc:/HomeOS/shaders/).
qt_add_shaders(homeos-display "shaders"
    PREFIX /HomeOS
    FILES
        shaders/gradienttile.frag
)

target_link_libraries(homeos-display PRIVATE homeos-core
    Qt6::Gui Qt6::Network Qt6::Qml Qt6::Quick Qt6::Concurrent Qt6::Multimedia Qt6::WebSockets)

# Demo photos and videos sit next to the binary (build tree) or in share/ (installed).
add_custom_command(TARGET homeos-display POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory ${CMAKE_CURRENT_SOURCE_DIR}/resources/demo/media
            $<TARGET_FILE_DIR:homeos-display>/demo-media)
install(DIRECTORY resources/demo/media/ DESTINATION share/homeos/demo-media)

install(TARGETS homeos-display RUNTIME DESTINATION bin)
install(PROGRAMS deploy/homeos-system DESTINATION libexec)

if(HOMEOS_BUILD_TESTS)
    find_package(Qt6 6.4 QUIET COMPONENTS Test)
    if(Qt6Test_FOUND)
        enable_testing()
        add_subdirectory(tests)
    else()
        message(STATUS "Qt Test not found; skipping the display unit tests")
    endif()
endif()
