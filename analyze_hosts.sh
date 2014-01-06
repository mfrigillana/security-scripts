#!/bin/bash

# analyze_hosts - Scans one or more hosts on security vulnerabilities
#
# Copyright (C) 2012-2014 Peter Mosmans
#                         <support AT go-forward.net>
#
# This source code (shell script) is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

# TODO: - preflight checks for all tools
#       - preflight check on hostname  
#       - trap control (session management, cancel scan/host/all hosts)
#       - cleanup of non-function code

name=analyze_hosts
version="0.41 (06-01-2014)"

# statuses
declare -c CLOSED=-1
declare -c UNKNOWN=0
declare -c OPEN=1
declare -c UP=1
declare -c NONEWLINE=1
declare -c BASIC=1
declare -c ADVANCED=2
declare -c ALTERNATIVE=4

# logging and verboseness
declare -c QUIET=1
declare -c STDOUT=2
declare -c VERBOSE=4
declare -c LOGFILE=8
declare -c RAWLOGS=16
declare -c SEPARATELOGS=32

# scantypes, defaults
declare -i fingerprint=$UNKNOWN
declare -i nikto=$UNKNOWN
declare -i portscan=$UNKNOWN
declare -i sslscan=$UNKNOWN
declare -i trace=$UNKNOWN
declare -i whois=$UNKNOWN
declare -i hoststatus=$UNKNOWN
declare -i loglevel=$STDOUT
declare -i portstatus=$UNKNOWN

datestring=$(date +%Y-%m-%d)
workdir=/tmp

# temporary files
portselection=/tmp/$name-$(date +%s)-portselection.tmp
tmpfile=/tmp/$name.tmp

# colours
declare -c BLUE='\E[1;49;96m'
declare -c LIGHTBLUE='\E[2;49;96m'
declare -c RED='\E[1;49;31m'
declare -c LIGHTRED='\E[2;49;31m'
declare -c GREEN='\E[1;49;32m'
declare -c LIGHTGREEN='\E[2;49;32m'

trap cleanup INT
umask 177

# define functions
prettyprint() {
    if (($loglevel&$QUIET)); then return; fi
    echo -ne $2
    if [[ "$3" == "$NONEWLINE" ]]; then
        echo -n "$1"
    else
        echo "$1"
    fi
    tput sgr0
}

usage() {
    prettyprint "$name version $version" $BLUE
    prettyprint "      (c) 2012-2014 Peter Mosmans [Go Forward]" $LIGHTBLUE
    prettyprint "      Licensed under the Mozilla Public License 2.0" $LIGHTBLUE
    echo ""
    echo " usage: $0 [OPTION]... [HOST]"
    echo ""
    echo "Scanning options:"
    echo " -a, --all               perform all basic scans" 
    echo "     --max               perform all advanced scans (more thorough)" 
    echo " -b, --basic             perform basic scans (fingerprint, ssl, trace)" 
    echo "     --filter=FILTER     only proceed with scan of HOST if WHOIS"
    echo "                         results of HOST matches regexp FILTER"
    echo " -f, --fingerprint       perform web fingerprinting"  
    echo " -n                      nikto webscan"
    echo "     --nikto             nikto webscan (port 80 and port 443)"
    echo " -p, --ports             nmap portscan"
    echo "     --allports          nmap portscan (all ports)"
    echo " -s                      check SSL configuration"
    echo "     --ssl               extra check for SSL configuration"
    echo " -t                      check webserver for HTTP TRACE method"
    echo "     --trace             extra check for HTTP TRACE method"
    echo " -w, --whois             perform WHOIS lookup"
    echo " -W                      confirm WHOIS results before continuing scan"
    echo ""
    echo "Logging and input file:"
    echo " -d, --directory=DIR     location of temporary files (default /tmp)"
    echo " -i, --inputfile=FILE    use a file containing hostnames"
    echo " -l, --log               log each scan in a separate logfile"
    echo " -o, --output=FILE       concatenate all results into FILE"
    echo " -q, --quiet             quiet"
    echo " -v, --verbose           print more information on screen"
    echo ""
    echo "     --version           print version information and exit"
    echo ""
    prettyprint "                         BLUE: status messages" $BLUE
    prettyprint "                         GREEN: secure settings" $GREEN
    prettyprint "                         RED: possible vulnerabilities" $RED
    echo ""
    echo " [HOST] can be a single (IP) address or an IP range, eg. 127.0.0.1-255"
    echo ""
    echo "example: $0 -a --filter Amazon www.google.com"
    echo ""
}

# setlogfilename (name)
# sets the GLOBAL variable logfile and currentscan
setlogfilename() {
    logfile=${target}_$1_${datestring}.txt
    currentscan=$1
}

purgelogs() {
    if [[ -f "$logfile" ]]; then
        if (($loglevel&$VERBOSE)); then showstatus "$(cat $logfile)"; fi
        if (($loglevel&$RAWLOGS)); then
            grep -v '^[#%]' $logfile >> $outputfile
        fi
        if !(($loglevel&$SEPARATELOGS)); then rm $logfile 1>/dev/null 2>&1; fi
    fi
    currentscan=
}

# showstatus (message) [COLOR] [NONEWLINE]
showstatus() {
    if [[ -z "$1" ]]; then return; fi
    if [[ ! -z "$2" ]]; then
        if [[ "$2" == "$NONEWLINE" ]]; then
            if !(($loglevel&$QUIET)); then echo -n "$1"; fi
            if (($loglevel&$LOGFILE)); then echo -n "$1" >> $outputfile; fi
        else
            prettyprint "$1" $2 $3
            if (($loglevel&$LOGFILE)); then echo "$1" >> $outputfile; fi
        fi
    else
            if !(($loglevel&$QUIET)); then echo "$1"; fi
        if (($loglevel&$LOGFILE)); then echo "$1" >> $outputfile; fi
    fi
}

version() {
    curl --version
    echo ""
    nikto -Version
    echo ""
    nmap -V
    echo ""
    sslscan --version
    echo ""
    prettyprint "$name version $version" $BLUE
    prettyprint "      (c) 2013-2014 Peter Mosmans [Go Forward]" $LIGHTBLUE
    prettyprint "      Licensed under the Mozilla Public License 2.0" $LIGHTBLUE
    echo ""
}

checkifportopen() {
    portstatus=$UNKNOWN
    if [[ -s "$portselection" ]]; then
        portstatus=$CLOSED
        grep -q " $1/open/" $portselection && portstatus=$OPEN
    fi
}

do_sslscan() {
    checkifportopen 443
    if (($portstatus==$CLOSED)); then
        showstatus "port 443 closed" $BLUE
        return
    fi

    setlogfilename "sslscan"
    if (($sslscan==$BASIC)); then
        showstatus "performing sslscan..."
        sslscan --no-failed $target:443 > $logfile
        grep -qe "ERROR: Could not open a connection to host $target on port 443" $logfile||portstatus=$CLOSED
        if (($portstatus==$CLOSED)) ; then
            showstatus "could not connect to port 443" $BLUE
        else
            showstatus "$(awk '/(Accepted).*(SSLv2|EXP|MD5|NULL| 40| 56)/{print $2,$3,$4,$5}' $logfile)" $RED
        fi
        purgelogs
    fi

    if (($sslscan>=$ADVANCED)); then
        showstatus "performing nmap sslscan..."
        nmap -p 443,8080 --script ssl-enum-ciphers --open -oN $logfile $target 1>/dev/null 2>&1 </dev/null
        if [[ -s $logfile ]] ; then
            showstatus "$(awk '/( - )(broken|weak|unknown)/{print $2}' $logfile)" $RED
        else
            showstatus "could not connect to port 443" $BLUE
        fi
        purgelogs
    fi
}

do_fingerprint() {
    checkifportopen 80
    if (($portstatus==$CLOSED)); then
        showstatus "port 80 closed" $BLUE
    else
        setlogfilename "whatweb"
        showstatus "performing whatweb fingerprinting..."
        whatweb -a3 --color never $target --log-brief $logfile 1>/dev/null 2>&1
        purgelogs
    fi
}

do_nikto() {
    checkifportopen 80
    if (($portstatus==$CLOSED)); then
        showstatus "port 80 closed" $BLUE
    else
        setlogfilename "nikto"
        showstatus "performing nikto webscan on port 80... " $NONEWLINE
        if [[ $target =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            showstatus "FQDN preferred over IP address"
        fi
        nikto -host $target -Format txt -output $logfile 1>/dev/null 2>&1 </dev/null
        purgelogs
    fi

    if (($nikto&$ADVANCED)); then
        checkifportopen 443
        if (($portstatus==$CLOSED)); then
            showstatus "port 443 closed" $BLUE
        else
            setlogfilename "nikto"
            showstatus "performing nikto webscan on port 443... " $NONEWLINE
            if [[ $target =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                showstatus "FQDN preferred over IP address"
            fi
            nikto -host $target:443 -ssl -Format txt -output $logfile 1>/dev/null 2>&1 </dev/null
            purgelogs
        fi
    fi
}

do_portscan() {
    setlogfilename "nmap"
    hoststatus=$UNKNOWN
    if (($portscan>=$ADVANCED)); then
        showstatus "performing advanced nmap portscan (all ports)... " $NONEWLINE
        nmap --open -p- -sV -sC -oN $logfile -oG $portselection $target 1>/dev/null 2>&1 </dev/null
    else
        showstatus "performing nmap portscan... " $NONEWLINE
        nmap --open -sV -sC -oN $logfile -oG $portselection $target 1>/dev/null 2>&1 </dev/null
    fi
    grep -q "0 hosts up" $portselection || hoststatus=$UP
    if (($hoststatus<$UP)); then
        showstatus "host down" $BLUE
    else
        showstatus "host is up" $BLUE
    fi
    # show logfiles regardless of verbose level
    previousloglevel=$loglevel
    let "loglevel=loglevel|$VERBOSE"
    purgelogs
    loglevel=$previousloglevel
}

do_trace() {
    checkifportopen 80
    if (($portstatus==$CLOSED)); then
        showstatus "port 80 closed" $GREEN
    else
        setlogfilename "curl"
        showstatus "trying TRACE method on port 80... " $NONEWLINE
        curl -q --insecure -i -m 30 -X TRACE -o $logfile http://$target/ 1>/dev/null 2>&1
        if [[ -s $logfile ]]; then
            status=$(awk 'NR==1 {print $2}' $logfile)
            if [[ $status -le 302 ]]; then
                showstatus "TRACE enabled on port 80" $RED
            else
                showstatus "disabled (HTTP statuscode $status)" $GREEN
            fi
        else
            showstatus "could not connect to port 80" $GREEN
        fi
        purgelogs
    fi

    checkifportopen 443
    if (($portstatus==$CLOSED)); then
        showstatus "port 443 closed" $GREEN
    else
        setlogfilename "curl"
        showstatus "trying TRACE method on port 443... " $NONEWLINE
        curl -q --insecure -i -m 30 -X TRACE -o $logfile https://$target/ 1>/dev/null 2>&1
        if [[ -s $logfile ]]; then
            status=$(awk 'NR==1 {print $2}' $logfile)
            if [[ $status -eq 200 ]]; then
                showstatus "TRACE enabled on port 443" $RED
            else
                showstatus "disabled (HTTP statuscode $status)" $GREEN
            fi
        else
            showstatus "could not connect to port 443" $BLUE
        fi
        purgelogs
    fi

    if (($trace>=$ADVANCED)); then
        setlogfilename "nmap-trace"
        showstatus "trying nmap TRACE method on ports 80,443 and 8080... " $NONEWLINE
        nmap -p80,443,8080 --open --script http-trace -oN $logfile $target 1>/dev/null 2>&1 </dev/null
	if [[ -s $logfile ]]; then
        status="$(awk '{FS="/";a[++i]=$1}/TRACE is enabled/{print "TRACE enabled on port "a[NR-1]}' $logfile)"
        if [[ -z "$status" ]]; then
            showstatus "disabled"  $GREEN
        else
            showstatus "$status" $RED
        fi
        purgelogs
fi
    fi
}

execute_all() {
    if (($whois>=$BASIC)); then
        local nomatch=
        local ip=
        setlogfilename whois
        if [[ $target =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            ip=$target
            local reverse=$(host $target|awk '{print $5}')
            if [[ "$reverse" == "3(NXDOMAIN)" ]]; then
                showstatus "$target does not resolve to a PTR record" 
            else
                showstatus "$target resolves to " $NONEWLINE
                showstatus $reverse $BLUE
            fi
        else
            ip=$(host -c IN $target|awk '/address/{print $4}')
            if [[ ! -n "$ip" ]]; then
                showstatus "$target does not resolve to an IP address - aborting scans" $RED
                purgelogs
                return
            else
                showstatus "$target resolves to $ip" 
            fi
        fi
        whois -H $ip > $logfile
        showstatus "$(grep -iE '^(inetnum|netrange|netname|nettype|descr|orgname|orgid|originas|country|origin):(.*)[^ ]$' $logfile)"
        if [[ -n "$filter" ]]; then
            if grep -qiE "^(inetnum|netrange|netname|nettype|descr|orgname|orgid|originas|country|origin):.*($filter)" $logfile; then
                showstatus "WHOIS info matches $filter - continuing scans" $GREEN
            else
                showstatus "WHOIS info doesn't match $filter - aborting scans on $target" $RED
                purgelogs
                return
            fi
        fi

        if (($whois&$ADVANCED)); then
            read -p "press any key to continue: " failsafe < stdin
        fi
        purgelogs
    fi

    if (($portscan>=$BASIC)); then do_portscan; fi
    if (($fingerprint>=$BASIC)); then do_fingerprint; fi
    if (($nikto>=$BASIC)); then do_nikto; fi
    if (($sslscan>=$BASIC)); then do_sslscan; fi
    if (($trace>=$BASIC)); then do_trace; fi
    if [[ ! -n "$portselection" ]]; then rm $portselection 1>/dev/null 2>&1; fi
}

looptargets() {
    if [[ -s "$inputfile" ]]; then
        total=$(wc -l < $inputfile)
        counter=1
        while read target; do
            showstatus ""
            showstatus "working on " $NONEWLINE
            showstatus "$target" $BLUE $NONEWLINE
            showstatus " ($counter of $total)"
            execute_all
            let counter=$counter+1
        done < "$inputfile"
    else
        showstatus ""
        showstatus "working on " $NONEWLINE
        showstatus "$target" $BLUE
        execute_all
    fi
}

cleanup() {
    showstatus "cleaning up temporary files.."
    if [[ -f "$logfile" ]]; then
        showstatus "dirty shutdown during $currentscan detected"
#        showstatus "scanstatus is saved - you can resume this scan" 
    fi
    purgelogs
    if [[ -s "$portselection" ]]; then rm "$portselection" ; fi
    if [[ -s "$tmpfile" ]]; then rm "$tmpfile" ; fi
    if [[ -n "$workdir" ]]; then popd 1>/dev/null ; fi
    showstatus "ended on $(date +%d-%m-%Y' at '%R)"
    exit
}

if ! options=$(getopt -o ad:fi:lno:pqstvwWy -l allports,directory:,filter:,fingerprint,inputfile:,log,max,nikto,output:,ports,quiet,ssl,trace,version,whois -- "$@") ; then
    usage
    exit 1
fi 

eval set -- $options
if [[ "$#" -le 1 ]]; then
    usage
    exit 1
fi

fulloptions=$@

while [[ $# -gt 0 ]]; do
    case $1 in
        -a|--all) 
            fingerprint=$BASIC
            nikto=$BASIC
            portscan=$BASIC
            sslscan=$BASIC
            trace=$BASIC
            whois=$BASIC;;
        --allports) portscan=$ADVANCED;;
        -f|--fp) fingerprint=$BASIC;;
        -d|--directory) workdir=$2
                        if [[ -n "$workdir" ]]; then 
                            [[ -d $workdir ]] && mkdir $workdir 1>/dev/null
                        fi
                        shift ;;
        --filter) filter="$2"
                  whois=$ADVANCED
                  shift ;;
        -i|--inputfile) inputfile="$2"
                        if [[ ! -s "$inputfile" ]]; then
                            echo "error: cannot find $inputfile" 
                            exit 1
                        fi           
                        shift ;;
        -l) log="TRUE";;
        --max)             
            fingerprint=$ADVANCED
            nikto=$ADVANCED
            portscan=$ADVANCED
            sslscan=$ADVANCED
            trace=$ADVANCED
            whois=$ADVANCED;; 
        -n) nikto=$BASIC;;
        --nikto) nikto=$ADVANCED;;
        -o|--output)
            let "loglevel=loglevel|$LOGFILE"
            outputfile=$2
            if [[ ! $outputfile =~ ^/ ]]; then 	        
                outputfile=$(pwd)/$outputfile
            fi
            [[ -s $outputfile ]] && appendfile=1
            shift ;;
        -p|--ports) portscan=$BASIC;;
        -q|--quiet) let "loglevel=loglevel|$QUIET";;
        -s) sslscan=$BASIC;;
        --ssl) sslscan=$ADVANCED;;
        -t) trace=$BASIC;;
        --trace) trace=$ADVANCED;;
        -v) let "loglevel=loglevel|$VERBOSE";;
        --version) version;
                   exit 0;;
        -w|--whois) whois=$BASIC;;
        -W) let "whois=whois|$ADVANCED";;
        (--) shift; 
             break;;
        (-*) echo "$0: unrecognized option $1" 1>&2; exit 1;;
        (*) break;;
    esac
    shift
done

if [[ ! -s "$inputfile" ]]; then
    if [[ ! -n "$1" ]]; then
        echo "Nothing to do... no target specified"
        exit
    fi
    if [[ $1 =~ [0-9]-[0-9] ]]; then
        nmap -nsL $1 2>/dev/null|awk '/scan report/{print $5}' >$tmpfile
        inputfile=$tmpfile
    fi
    target=$1
fi


showparameters() {
    if (($loglevel&$LOGFILE)); then
        if [[ -n $appendfile ]]; then
            showstatus "appending to existing file $outputfile"
        else
            showstatus "logging to $outputfile"
        fi
    fi
    showstatus "scanparameters: $fulloptions"
}

showstatus "$name version $version starting on $(date +%d-%m-%Y' at '%R)"
showparameters

if [[ -n "$workdir" ]]; then pushd $workdir 1>/dev/null; fi

looptargets
cleanup
