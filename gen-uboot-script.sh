#!/bin/bash

offset=$((2*1024*1024))

function add_size()
{
    local filename=$1
    local size=`stat --printf="%s" $filename`
    memaddr=$(( $memaddr + $size + $offset - 1))
    memaddr=$(( $memaddr & ~($offset - 1) ))
    memaddr=`printf "0x%X\n" $memaddr`
}

function load_file()
{
    local filename=$1

    echo "$LOAD_CMD $memaddr $filename" >> $UBOOT_SOURCE
    add_size $filename
}

function check_file_type()
{
    local filename=$1
    local type="$2"

    file $filename | grep "$type" &> /dev/null
    if test $? != 0
    then
        echo Wrong file type "$filename". It shold be "$type".
    fi
}

function check_compressed_file_type()
{
    local filename=$1
    local type="$2"

    file $filename | grep "gzip compressed data" &> /dev/null
    if test $? == 0
    then
        local tmp=`mktemp`
        cat $filename | gunzip > $tmp
        filename=$tmp
    fi
    check_file_type $filename "$type"
}

. config

rm -f $UBOOT_SOURCE $UBOOT_SCRIPT
memaddr=$(( $MEMORY_START + $offset ))
memaddr=`printf "0x%X\n" $memaddr`

check_file_type $DEVICE_TREE "Device Tree Blob"
device_tree_addr=$memaddr
load_file $DEVICE_TREE

check_compressed_file_type $XEN "MS-DOS executable"
xen_addr=$memaddr
mkimage -A arm64 -T kernel -C none -a $xen_addr -e $xen_addr -d $XEN "$XEN".uboot &> /dev/null
load_file "$XEN".uboot

check_compressed_file_type $DOM0_KERNEL "MS-DOS executable"
load_file $DOM0_KERNEL

check_compressed_file_type $DOM0_RAMDISK "cpio archive"
dom0_ramdisk_addr=$memaddr
mkimage -A arm64 -T ramdisk -C gzip -a $dom0_ramdisk_addr -e $dom0_ramdisk_addr -d $DOM0_RAMDISK "$DOM0_RAMDISK".uboot &> /dev/null
load_file "$DOM0_RAMDISK".uboot

i=0
while test $i -lt $NUM_DOMUS
do
    check_compressed_file_type ${DOMU_KERNEL[$i]} "MS-DOS executable"
    load_file ${DOMU_KERNEL[$i]}
    check_compressed_file_type ${DOMU_RAMDISK[$i]} "cpio archive"
    load_file ${DOMU_RAMDISK[$i]}
    i=$(( $i + 1 ))
done

memaddr=$(( $MEMORY_END - $memaddr ))
if test $memaddr -lt 0
then
    echo Error, not enough memory to load all binaries
    exit 1
fi

echo "bootm $xen_addr $dom0_ramdisk_addr $device_tree_addr" >> $UBOOT_SOURCE

memaddr=$(( $memaddr + $offset ))
memaddr=`printf "0x%X\n" $memaddr`
uboot_addr="$memaddr"
mkimage -A arm64 -T script -C none -a $uboot_addr -e $uboot_addr -d $UBOOT_SOURCE "$UBOOT_SCRIPT" &> /dev/null
echo "Generated uboot script $UBOOT_SCRIPT, to be loaded at address $uboot_addr:"
echo "$LOAD_CMD $uboot_addr $UBOOT_SCRIPT; source $uboot_addr"
