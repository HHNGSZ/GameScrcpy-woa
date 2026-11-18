foreach(input IN ITEMS GS DLL WORK)
    if("${${input}}" STREQUAL "")
        message(FATAL_ERROR "NativeArchitecturesCheck.cmake needs -D${input}=<value>")
    endif()
endforeach()
if("${HOST}" STREQUAL "")
    set(HOST "x64")
endif()
if(HOST STREQUAL "arm64")
    set(OTHER "x64")
else()
    set(OTHER "arm64")
endif()

file(TO_CMAKE_PATH "${GS}" program)
file(TO_CMAKE_PATH "${DLL}" library)
file(TO_CMAKE_PATH "${WORK}" work)
file(REMOVE_RECURSE "${work}")

function(gs_run name)
    execute_process(COMMAND "${program}" ${ARGN} RESULT_VARIABLE result OUTPUT_VARIABLE output ERROR_VARIABLE problem)
    set(${name}_result "${result}" PARENT_SCOPE)
    set(${name}_output "${output}" PARENT_SCOPE)
    set(${name}_problem "${problem}" PARENT_SCOPE)
endfunction()

# One folder per case, holding the same DLL under both processor folders. Only the host's copy is
# ever valid: listing it under the other processor is the mistake the check is about.
function(gs_folder name dlls)
    set(folder "${work}/${name}")
    file(MAKE_DIRECTORY "${folder}/bin/x64" "${folder}/bin/arm64")
    file(COPY_FILE "${library}" "${folder}/bin/x64/clock.dll")
    file(COPY_FILE "${library}" "${folder}/bin/arm64/clock.dll")
    file(WRITE "${folder}/manifest.json"
         "{\"schemaVersion\": 1, \"id\": \"gstest.architectures\", \"version\": \"1.0.0\", \"gamescrcpy\": \"2.1\", "
         "\"name\": \"Architectures\", "
         "\"license\": \"MIT\", \"requires\": {\"native\": \"^2.0\"}, \"contributes\": {\"native\": {\"dll\": ${dlls}}}}")
endfunction()

gs_folder(fits "{\"${HOST}\": \"bin/${HOST}/clock.dll\"}")
gs_run(fits validate "${work}/fits" --json)
if(NOT fits_result EQUAL 0)
    message(FATAL_ERROR "gs validate refused a ${HOST} DLL listed for ${HOST} (${fits_result}):\n${fits_output}${fits_problem}")
endif()
string(JSON architecture GET "${fits_output}" libraries 0 architecture)
string(JSON machine GET "${fits_output}" libraries 0 machine)
string(JSON entry GET "${fits_output}" libraries 0 entry)
if(NOT architecture STREQUAL "${HOST}" OR NOT machine STREQUAL "${HOST}" OR NOT entry)
    message(FATAL_ERROR "gs validate did not report the ${HOST} DLL and its gs_ext_main:\n${fits_output}")
endif()

gs_folder(plain "\"bin/${HOST}/clock.dll\"")
gs_run(plain validate "${work}/plain")
if(NOT plain_result EQUAL 0 OR NOT plain_output MATCHES "bin/${HOST}/clock[.]dll: ${HOST}, exports gs_ext_main")
    message(FATAL_ERROR "gs validate did not check the one DLL of the string form:\n${plain_output}${plain_problem}")
endif()

gs_folder(mixed "{\"${HOST}\": \"bin/${HOST}/clock.dll\", \"${OTHER}\": \"bin/${OTHER}/clock.dll\"}")
gs_run(mixed validate "${work}/mixed")
if(mixed_result EQUAL 0 OR
   NOT mixed_output MATCHES "native-machine-mismatch at [$][.]contributes[.]native[.]dll\\[\"${OTHER}\"\\]")
    message(FATAL_ERROR "gs validate took a ${HOST} DLL listed for ${OTHER}:\n${mixed_output}${mixed_problem}")
endif()

gs_folder(missing "{\"${HOST}\": \"bin/${HOST}/clock.dll\", \"${OTHER}\": \"bin/${OTHER}/gone.dll\"}")
gs_run(missing validate "${work}/missing")
if(missing_result EQUAL 0 OR
   NOT missing_output MATCHES "file-missing at [$][.]contributes[.]native[.]dll\\[\"${OTHER}\"\\]")
    message(FATAL_ERROR "gs validate did not miss the ${OTHER} DLL:\n${missing_output}${missing_problem}")
endif()
message(STATUS "the ${HOST} DLL fits ${HOST} in both forms; listed for ${OTHER} or missing, it was caught")
