#!/bin/bash

source /opt/mannheim-network/spacex-script/scripts/utils.sh
source /opt/mannheim-network/spacex-script/scripts/version.sh
source /opt/mannheim-network/spacex-script/scripts/config.sh
source /opt/mannheim-network/spacex-script/scripts/tools.sh
export EX_SWORKER_ARGS=''


start()
{
    if [ ! -f "$composeyaml" ]; then
        log_err "No configuration file, please set config"
        exit 1
    fi

    if [ x"$1" = x"" ]; then
        log_info "Start spacex"

        if [ -f "$builddir/api/api_config.json" ]; then
            local chain_ws_url=`cat $builddir/api/api_config.json | jq .chain_ws_url`
            if [ x"$chain_ws_url" == x"\"ws://127.0.0.1:19944\"" ]; then
                start_chain
                if [ $? -ne 0 ]; then
                    docker-compose -f $composeyaml down
                    exit 1
                fi
            else
                log_info "API will connect to other chain: ${chain_ws_url}"
            fi
        else
            start_chain
            if [ $? -ne 0 ]; then
                docker-compose -f $composeyaml down
                exit 1
            fi
        fi

        start_sworker
        if [ $? -ne 0 ]; then
            docker-compose -f $composeyaml down
            exit 1
        fi

        start_api
        if [ $? -ne 0 ]; then
            docker-compose -f $composeyaml down
            exit 1
        fi

        start_sfrontend
        if [ $? -ne 0 ]; then
            docker-compose -f $composeyaml down
            exit 1
        fi

        start_ipfs
        if [ $? -ne 0 ]; then
            docker-compose -f $composeyaml down
            exit 1
        fi

        log_success "Start spacex success"
        return 0
    fi

    if [ x"$1" = x"chain" ]; then
        log_info "Start chain service"
        start_chain
        if [ $? -ne 0 ]; then
            exit 1
        fi
        log_success "Start chain service success"
        return 0
    fi

    if [ x"$1" = x"api" ]; then
        log_info "Start api service"
        start_api
        if [ $? -ne 0 ]; then
            exit 1
        fi
        log_success "Start api service success"
        return 0
    fi

    if [ x"$1" = x"storage" ]; then
        log_info "Start storage service"
        shift
        start_sworker $@
        if [ $? -ne 0 ]; then
            exit 1
        fi
        log_success "Start storage service success"
        return 0
    fi

    if [ x"$1" = x"sfrontend" ]; then
        log_info "Start sfrontend service"
        start_sfrontend
        if [ $? -ne 0 ]; then
            exit 1
        fi
        log_success "Start sfrontend service success"
        return 0
    fi

    if [ x"$1" = x"ipfs" ]; then
        log_info "Start ipfs service"
        start_ipfs
        if [ $? -ne 0 ]; then
            exit 1
        fi
        log_success "Start ipfs service success"
        return 0
    fi

    help
    return 1
}

stop()
{
    if [ x"$1" = x"" ]; then
        log_info "Stop spacex"
        stop_chain
        stop_sfrontend
        stop_api
        stop_storage
        stop_ipfs
        log_success "Stop spacex success"
        return 0
    fi

    if [ x"$1" = x"chain" ]; then
        log_info "Stop chain service"
        stop_chain
        log_success "Stop chain service success"
        return 0
    fi

    if [ x"$1" = x"api" ]; then
        log_info "Stop api service"
        stop_api
        log_success "Stop api service success"
        return 0
    fi

    if [ x"$1" = x"stroage" ]; then
        log_info "Stop storage service"
        stop_storage
        log_success "Stop storage service success"
        return 0
    fi

    if [ x"$1" = x"sfrontend" ]; then
        log_info "Cannot stop the sfrontend service alone, this will affect your benefits"
        return 0
    fi

    if [ x"$1" = x"ipfs" ]; then
        log_info "Stop ipfs service"
        stop_ipfs
        log_success "Stop ipfs service success"
        return 0
    fi

    help
    return 1
}

start_chain()
{
    if [ ! -f "$composeyaml" ]; then
        log_err "No configuration file, please set config"
        return 1
    fi

    check_docker_status spacex
    if [ $? -eq 0 ]; then
        return 0
    fi

    local config_file=$builddir/chain/chain_config.json
    if [ x"$config_file" = x"" ]; then
        log_err "Please give right chain config file"
        return 1
    fi

    local chain_port=`cat $config_file | jq .port`

    if [ x"$chain_port" = x"" ] || [ x"$chain_port" = x"null" ]; then
        chain_port=30888
    fi

    if [ $chain_port -lt 0 ] || [ $chain_port -gt 65535 ]; then
        log_err "The range of chain port is 0 ~ 65535"
        return 1
    fi

    local res=0
    check_port $chain_port
    res=$(($?|$res))
    check_port 19933
    res=$(($?|$res))
    check_port 19944
    res=$(($?|$res))
    if [ $res -ne 0 ]; then
        return 1
    fi

    docker-compose -f $composeyaml up -d spacex
    if [ $? -ne 0 ]; then
        log_err "Start spacex-api failed"
        return 1
    fi
    return 0
}

stop_chain()
{
    check_docker_status spacex
    if [ $? -ne 1 ]; then
        log_info "Stopping spacex chain service"
        docker stop spacex &>/dev/null
        docker rm spacex &>/dev/null
    fi
    return 0
}


### start storage ###
start_storage()
{
    if [ ! -f "$composeyaml" ]; then
        log_err "No configuration file, please set config"
        return 1
    fi

    if [ -d "$builddir/storage" ]; then
        local a_or_b=`cat $basedir/etc/storage.ab`
        check_docker_status spacex-storage-$a_or_b
        if [ $? -eq 0 ]; then
            return 0
        fi

        check_port 12222
        if [ $? -ne 0 ]; then
            return 1
        fi

        if [ -f "$scriptdir/install_sgx.sh" ]; then
            $scriptdir/install_sgx.sh
            if [ $? -ne 0 ]; then
                log_err "Install sgx dirver failed"
                return 1
            fi
        fi

        if [ ! -e "/dev/isgx" ]; then
            log_err "Your device can't install sgx dirver, please check your CPU and BIOS to determine if they support SGX."
            return 1
        fi
        EX_STORAGE_ARGS=$@ docker-compose -f $composeyaml up -d spacex-storage-$a_or_b
        if [ $? -ne 0 ]; then
            log_err "Start spacex-storage-$a_or_b failed"
            return 1
        fi
    fi
    return 0
}

stop_storage()
{
    check_docker_status spacex-storage-a
    if [ $? -ne 1 ]; then
        log_info "Stopping spacex storage A service"
        docker stop spacex-storage-a &>/dev/null
        docker rm spacex-storage-a &>/dev/null
    fi

    check_docker_status spacex-storage-b
    if [ $? -ne 1 ]; then
        log_info "Stopping spacex storage B service"
        docker stop spacex-storage-b &>/dev/null
        docker rm spacex-storage-b &>/dev/null
    fi

    return 0
}

start_api()
{
    if [ ! -f "$composeyaml" ]; then
        log_err "No configuration file, please set config"
        return 1
    fi

    if [ -d "$builddir/storage" ]; then
        check_docker_status spacex-api
        if [ $? -eq 0 ]; then
            return 0
        fi

        check_port 56666
        if [ $? -ne 0 ]; then
            return 1
        fi

        docker-compose -f $composeyaml up -d spacex-api
        if [ $? -ne 0 ]; then
            log_err "Start spacex-api failed"
            return 1
        fi
    fi
    return 0
}

stop_api()
{
    check_docker_status spacex-api
    if [ $? -ne 1 ]; then
        log_info "Stopping spacex API service"
        docker stop spacex-api &>/dev/null
        docker rm spacex-api &>/dev/null
    fi
    return 0
}

start_sfrontend()
{
    if [ ! -f "$composeyaml" ]; then
        log_err "No configuration file, please set config"
        return 1
    fi

    if [ -d "$builddir/sfrontend" ]; then
        check_docker_status spacex-sfrontend
        if [ $? -eq 0 ]; then
            return 0
        fi

        docker-compose -f $composeyaml up -d spacex-sfrontend
        if [ $? -ne 0 ]; then
            log_err "Start spacex-sfrontend failed"
            return 1
        fi

        local upgrade_pid=$(ps -ef | grep "/opt/mannheim-network/spacex-script/scripts/auto_sfrontend.sh" | grep -v grep | awk '{print $2}')
        if [ x"$upgrade_pid" != x"" ]; then
            kill -9 $upgrade_pid
        fi

        if [ -f "$scriptdir/auto_sfrontend.sh" ]; then
            nohup $scriptdir/auto_sfrontend.sh &>$basedir/auto_sfrontend.log &
            if [ $? -ne 0 ]; then
                log_err "Start spacex-sfrontend upgrade failed"
                return 1
            fi
        fi
    fi
    return 0
}

stop_sfrontend()
{
    local upgrade_pid=$(ps -ef | grep "/opt/mannheim-network/spacex-script/scripts/auto_stop_sfrontend.sh" | grep -v grep | awk '{print $2}')
	if [ x"$upgrade_pid" != x"" ]; then
		kill -9 $upgrade_pid
	fi

    check_docker_status spacex-sfrontend
    if [ $? -ne 1 ]; then
        log_info "Stopping spacex sfrontend service"
        docker stop spacex-sfrontend &>/dev/null
        docker rm spacex-sfrontend &>/dev/null
    fi
    return 0
}

start_ipfs()
{
    if [ ! -f "$composeyaml" ]; then
        log_err "No configuration file, please set config"
        return 1
    fi

    if [ -d "$builddir/ipfs" ]; then
        check_docker_status ipfs
        if [ $? -eq 0 ]; then
            return 0
        fi

        local res=0
        check_port 4001
        res=$(($?|$res))
        check_port 5001
        res=$(($?|$res))
        check_port 37773
        res=$(($?|$res))
        if [ $res -ne 0 ]; then
            return 1
        fi

        docker-compose -f $composeyaml up -d ipfs
        if [ $? -ne 0 ]; then
            log_err "Start ipfs failed"
            return 1
        fi
    fi
    return 0
}

stop_ipfs()
{
    check_docker_status ipfs
    if [ $? -ne 1 ]; then
        log_info "Stopping ipfs service"
        docker stop ipfs &>/dev/null
        docker rm ipfs &>/dev/null
    fi
    return 0
}





reload() {
    if [ x"$1" = x"" ]; then
        log_info "Reload all service"
        stop
        start
        log_success "Reload all service success"
        return 0
    fi

    if [ x"$1" = x"chain" ]; then
        log_info "Reload chain service"

        stop_chain
        start_chain

        log_success "Reload chain service success"
        return 0
    fi

    if [ x"$1" = x"api" ]; then
        log_info "Reload api service"

        stop_api
        start_api

        log_success "Reload api service success"
        return 0
    fi

    if [ x"$1" = x"storage" ]; then
        log_info "Reload storage service"

        stop_storage
        shift
        start_storage $@

        log_success "Reload storage service success"
        return 0
    fi

    if [ x"$1" = x"sfrontend" ]; then
        log_info "Reload sfrontend service"

        stop_sfrontend
        start_sfrontend

        log_success "Reload sfrontend service success"
        return 0
    fi

    if [ x"$1" = x"ipfs" ]; then
        log_info "Reload ipfs service"

        stop_ipfs
        start_ipfs

        log_success "Reload ipfs service success"
        return 0
    fi

    help
    return 1
}

########################################logs################################################

logs_help()
{
cat << EOF
Usage: spacex logs [OPTIONS] {chain|api|storage|storage-a|storage-b|sfrontend|ipfs}

Fetch the logs of a service

Options:
      --details        Show extra details provided to logs
  -f, --follow         Follow log output
      --since string   Show logs since timestamp (e.g. 2012-01-02T13:23:37) or relative (e.g. 42m for 42 minutes)
      --tail string    Number of lines to show from the end of the logs (default "all")
  -t, --timestamps     Show timestamps
      --until string   Show logs before a timestamp (e.g. 2012-01-02T13:23:37) or relative (e.g. 42m for 42 minutes)
EOF
}

logs()
{
    local name="${!#}"
    local array=( "$@" )
    local logs_help_flag=0
    unset "array[${#array[@]}-1]"

    if [ x"$name" == x"chain" ]; then
        check_docker_status spacex
        if [ $? -eq 1 ]; then
            log_info "Service spacex chain is not started now"
            return 0
        fi
        docker logs ${array[@]} -f spacex
        logs_help_flag=$?
    elif [ x"$name" == x"api" ]; then
        check_docker_status spacex-api
        if [ $? -eq 1 ]; then
            log_info "Service spacex API is not started now"
            return 0
        fi
        docker logs ${array[@]} -f spacex-api
        logs_help_flag=$?
    elif [ x"$name" == x"storage" ]; then
        local a_or_b=`cat $basedir/etc/storage.ab`
        check_docker_status spacex-storage-$a_or_b
        if [ $? -eq 1 ]; then
            log_info "Service spacex storage is not started now"
            return 0
        fi
        docker logs ${array[@]} -f spacex-storage-$a_or_b
        logs_help_flag=$?
    elif [ x"$name" == x"ipfs" ]; then
        check_docker_status ipfs
        if [ $? -eq 1 ]; then
            log_info "Service ipfs is not started now"
            return 0
        fi
        docker logs ${array[@]} -f ipfs
        logs_help_flag=$?
    elif [ x"$name" == x"sfrontend" ]; then
        check_docker_status spacex-sfrontend
        if [ $? -eq 1 ]; then
            log_info "Service spacex sfrontend is not started now"
            return 0
        fi
        docker logs ${array[@]} -f spacex-sfrontend
        logs_help_flag=$?
    elif [ x"$name" == x"storage-a" ]; then
        check_docker_status spacex-storage-a
        if [ $? -eq 1 ]; then
            log_info "Service spacex storage-a is not started now"
            return 0
        fi
        docker logs ${array[@]} -f spacex-storage-a
        logs_help_flag=$?
    elif [ x"$name" == x"storage-b" ]; then
        check_docker_status spacex-storage-b
        if [ $? -eq 1 ]; then
            log_info "Service spacex storage-b is not started now"
            return 0
        fi
        docker logs ${array[@]} -f spacex-storage-b
        logs_help_flag=$?
    elif [ x"$name" == x"sfrontend-upshell" ]; then
		local upgrade_pid=$(ps -ef | grep "/opt/mannheim-network/spacex-script/scripts/auto_sfrontend.sh" | grep -v grep | awk '{print $2}')
		if [ x"$upgrade_pid" == x"" ]; then
			log_info "Service spacex sfrontend upgrade shell is not started now"
			return 0
		fi
		tail -f $basedir/auto_sfrontend.log
    else
        logs_help
        return 1
    fi

    if [ $logs_help_flag -ne 0 ]; then
        logs_help
        return 1
    fi
}


