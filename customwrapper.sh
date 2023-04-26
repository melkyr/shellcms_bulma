#!/bin/bash
#20230423 improvement to store more default options when config file not read(?)
readonly available_editors=(
    'seamonkey|mozeditor'
    'bluegriffon|bluegriffon'
    'code|code -n'
    'hx|hx'
    'geany|geany -i'
    'vi|vi'
    )

function set_baseline_editor(){
    local editor exec_command
    local OLDIFS=$IFS
    IFS='|'
    for fields in "${available_editors[@]}"
    do
        read -r editor exec_command <<< "$fields"
        echo $editor
        echo $exec_command
        if which $editor >/dev/null; then
        
            EDITOR=$exec_command
            echo $EDITOR
            break
        fi
    done
    IFS=$OLDIFS
}
# Load a baseline for editors
 set_baseline_editor
#20230423
