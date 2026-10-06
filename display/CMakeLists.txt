cmake_minimum_required(VERSION 3.21)
project(homeos-display VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 6.4 REQUIRED COMPONENTS Core Gui Network Qml Quick Concurrent Multimedia)
qt_standard_project_setup()

qt_add_executable(homeos-display
    src/main.cpp
    src/backend/SupabaseClient.h   src/backend/SupabaseClient.cpp
    src/models/FamilyStore.h       src/models/FamilyStore.cpp
    src/models/Assistant.h         src/models/Assistant.cpp
    src/models/ColorSampler.h      src/models/ColorSampler.cpp
    src/hardware/DisplayController.h src/hardware/DisplayController.cpp
)

target_include_directories(homeos-display PRIVATE src)

set_source_files_properties(qml/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

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
        qml/components/Tag.qml
        qml/components/SegmentedControl.qml
        qml/components/TimeGrid.qml
        qml/components/MonthGrid.qml
        qml/components/Page.qml
        qml/components/AnimatedNumber.qml
        qml/components/VideoView.qml
        qml/screens/HomeScreen.qml
        qml/screens/CalendarScreen.qml
        qml/screens/TasksScreen.qml
        qml/screens/RewardsScreen.qml
        qml/screens/MediaScreen.qml
        qml/screens/MediaViewer.qml
        qml/screens/PlannerScreen.qml
        qml/screens/PhotoFrame.qml
        qml/screens/PairingScreen.qml
        qml/screens/AssistantPanel.qml
    RESOURCES
        resources/demo/family.json
        qml/components/KeyboardPanel.qml
)

target_link_libraries(homeos-display PRIVATE Qt6::Gui Qt6::Network Qt6::Qml Qt6::Quick Qt6::Concurrent Qt6::Multimedia)

# Demo photos and videos sit next to the binary (build tree) or in share/ (installed).
add_custom_command(TARGET homeos-display POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory ${CMAKE_CURRENT_SOURCE_DIR}/resources/demo/media
            $<TARGET_FILE_DIR:homeos-display>/demo-media)
install(DIRECTORY resources/demo/media/ DESTINATION share/homeos/demo-media)

install(TARGETS homeos-display RUNTIME DESTINATION bin)
