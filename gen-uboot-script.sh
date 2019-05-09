#!/bin/bash

offset=$((2*1024*1024))

function add_device_tree_kernel()
{
    local addr=$1
    local size=$2

    echo "            module@$addr {" >> $temp
	echo "                compatible = \"multiboot,kernel\", \"multiboot,module\";" >> $temp
	echo "                reg = <0x0 "$addr" 0x0 "$size">;" >> $temp
    echo "                bootargs = \"console=ttyAMA0\";" >> $temp
    echo "            };" >> $temp
}

function add_device_tree_ramdisk()
{
    local addr=$1
    local size=$2

    echo "            module@$addr {" >> $temp
    echo "                compatible = \"multiboot,ramdisk\", \"multiboot,module\";" >> $temp
	echo "                reg = <0x0 "$addr" 0x0 "$size">;" >> $temp
    echo "            };" >> $temp
}

function add_device_tree()
{
    local i=0
    local size=0
    local filename=$1
    local kernel_size=$(( $dom0_ramdisk_addr - $dom0_kernel_addr ))
    kernel_size=`printf "0x%X\n" $kernel_size`

    echo "        #address-cells = <0x2>;" >> $temp
	echo "        #size-cells = <0x2>;" >> $temp
    echo "        xen,xen-bootargs = \"console=dtuart dtuart=serial0 dom0_mem=1G bootscrub=0 serrors=forward vwfi=native sched=null\";" >> $temp
    echo "        dom0 {" >> $temp
	echo "           compatible = \"xen,linux-zimage\", \"xen,multiboot-module\";" >> $temp
	echo "           reg = <0x0 "$dom0_kernel_addr" 0x0 "$kernel_size">;" >> $temp
    echo "           bootargs = \"console=hvc0 earlycon=xen earlyprintk=xen\";" >> $temp
    echo "        };" >> $temp

    while test $i -lt $NUM_DOMUS
    do
        echo "        domU$i {" >> $temp
        echo "            compatible = \"xen,domain\";" >> $temp
        echo "            #address-cells = <0x2>;" >> $temp
		echo "            #size-cells = <0x2>;" >> $temp
		echo "            memory = <0x0 0x20000>;" >> $temp
		echo "            cpus = <0x1>;" >> $temp
		echo "            vpl011;" >> $temp
        size=`stat --printf="%s" ${DOMU_KERNEL[$i]}`
        add_device_tree_kernel ${domU_kernel_addr[$i]} $size
        size=`stat --printf="%s" ${DOMU_RAMDISK[$i]}`
        add_device_tree_ramdisk ${domU_ramdisk_addr[$i]} $size
        echo "        };" >> $temp
        i=$(( $i + 1 ))
    done
}

function filter_device_tree()
{
    local filename_dtb=$1
    local filename_dts="`basename -s .dtb $filename_dtb`".dts
    local temp=`mktemp`

    local skip=0
    local chosen=0

    mv -f $filename_dts "$filename_dts".bak
    dtc -I dtb -O dts $filename_dtb > $filename_dts 2>/dev/null

    while IFS= read -r line
    do
        if [[ $line == *"chosen"* ]]
        then
            chosen=1
        fi
        if [[ $chosen -eq 1 && ($line == *"address-cells"* || $line == *"size-cells"*) ]]
        then
            continue
        fi
        if [[ $line == *"dom0"* || $line == *"domU"* ]]
        then
            skip=1
            continue
        fi
        if [[ $skip -eq 1 && $line == *"{"* ]]
        then
            skip=2
        fi
        if [[ $skip -gt 0 && $line == *"};"* ]]
        then
            skip=$(( $skip - 1 ))
            continue
        fi
        if [[ $chosen -eq 1 && $skip -eq 0 && $line == *"};"* ]]
        then
            chosen=0;
            add_device_tree
        fi

        if [[ $skip -eq 0 ]]
        then
            echo "$line" >> $temp
        fi

    done < $filename_dts

    mv -f $filename_dtb "$filename_dtb".bak
    dtc -I dts -I dtb $temp > $filename_dtb 2>/dev/null
    mv $temp $filename_dts
}

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

check_compressed_file_type $XEN "MS-DOS executable"
xen_addr=$memaddr
mkimage -A arm64 -T kernel -C none -a $xen_addr -e $xen_addr -d $XEN "$XEN".uboot &> /dev/null
load_file "$XEN".uboot

check_compressed_file_type $DOM0_KERNEL "MS-DOS executable"
dom0_kernel_addr=$memaddr
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
    domU_kernel_addr[$i]=$memaddr
    check_compressed_file_type ${DOMU_RAMDISK[$i]} "cpio archive"
    load_file ${DOMU_RAMDISK[$i]}
    domU_ramdisk_addr[$i]=$memaddr
    i=$(( $i + 1 ))
done

check_file_type $DEVICE_TREE "Device Tree Blob"
filter_device_tree $DEVICE_TREE
device_tree_addr=$memaddr
load_file $DEVICE_TREE

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
