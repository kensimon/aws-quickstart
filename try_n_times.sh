#!/bin/bash

function try_n_times() {
    num_times=$1
    cmd=$2

    for i in $(seq 1 $num_times); do
        if [[ $i -le $num_times ]]; then
            eval "$cmd" && break || (test $i -lt $num_times && sleep 1)
        fi
    done
}

function do_something() {
    echo running stuff
    false
}

try_n_times 3 "do_something"
