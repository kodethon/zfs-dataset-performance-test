#!/bin/bash
#
# Measure the memory overhead associated with creating ZFS datasets

dataset_steps=$(seq 0 500 10000)
num_datasets_to_measure=20
root_dir=$(pwd)
num_drives=2
drive_size=2G
eval drives=($(seq -f "\"${root_dir}/%g.img\"" 1 ${num_drives}))
pid=$$
#current_date_time=$(date "+%Y-%m-%d_%H:%M:%S")
#outfile="measurements/measurements_${current_date_time}.txt"
outfile="measurements/measurements.txt"
existing_datasets=0
mem_unit="KB"

# ----------------- #
# helper functions  #
# ----------------- #

# TODO: It's possible that these slab info files are elsewhere in your
# specific installation, so make sure to check!
slabinfo_used() {
  # summed size of slabs in /proc/slabinfo (in bytes)
  awk_args="/zlib/ || /zio/ || /ddt/ || /arc/ || /dnode/ || /zfs/ || /znode/"
  awk_args="${awk_args} || /zil/ {s+=\$2*\$4} END {print s}"
  cat /proc/slabinfo  | awk "${awk_args}"
}

kmemslab_used() {
  # summed size of slabs in /proc/spl/kmem/slab (in bytes)
  awk_args="/zlib/ || /zio/ || /ddt/ || /arc/ || /dnode/ || /zfs/ || /znode/"
  awk_args="${awk_args} || /zil/ {s+=\$3} END {print s}"
  cat /proc/spl/kmem/slab  | awk "${awk_args}"
}

mem_used() {
  # get total (reported) kernel memory used in KB
  km=$(kmemslab_used)
  si=$(slabinfo_used)
  total_bytes=$(($km+$si))
  echo $(($total_bytes/1024))
}

increase_datasets_to() {
  for i in $(seq $((${existing_datasets}+1)) ${1}); do
    # hex=$(echo "obase=16; ${i}" | bc)
    dsname="${pool_name}/${i}"
    zfs create -p "${dsname}"
    # zfs create -o canmount=noauto "${dsname}" && zfs mount "${dsname}"
  done
  existing_datasets=${1}
}

create_outfile() {
  cols="existing created real_time user_time sys_time mem_used mem_cum"
  echo ${cols} > ${outfile}
}

proc_vmsize() {
  cat /proc/${1}/status | grep VmSize | awk '{print $2 " " $3}'
}

# Arguments:
#   1: number of datasets to create
measure_creation() {
  prior=$(echo ${existing_datasets})
  next=$((${prior}+${1}))
  stdbuf --output=0 echo "* Existing datasets: ${prior}"
  stdbuf --output=0 printf "--> Measuring creation of ${1} datasets (up to ${next})..."

  #start_mem=$(free -m | grep Mem | awk '{print $4}')
  #end_mem=$(free -m | grep Mem | awk '{print $4}')
  start_mem=$(mem_used) || exit 1

  exec 3>&1 4>&2
  time_out=$( { time increase_datasets_to ${next} 1>&3 2>&4; } 2>&1 | xargs)
  exec 3>&- 4>&-

  end_mem=$(mem_used) || exit 1
  mem_diff=$((${end_mem}-${start_mem}))

  # time runs increase_datasets_to in new shell, so we need to manually update
  existing_datasets=${next}

  real=$(awk '{print $2}' <<< ${time_out})
  user=$(awk '{print $4}' <<< ${time_out})
  sys=$(awk '{print $6}' <<< ${time_out})

  stdbuf --output=0 echo "done"
  stdbuf --output=0 echo "    Time to create new datasets: ${time_out}"
  stdbuf --output=0 echo "    Memory increase to create new datasets: ${mem_diff} ${mem_unit}"
  stdbuf --output=0 echo "    Cumulative memory usage: ${end_mem} ${mem_unit}"
  echo "${prior} ${1} ${real} ${user} ${sys} ${mem_diff} ${end_mem}" >> ${outfile}
}

# ------------------ #
# actual measurement #
# ------------------ #

# create files to serve as virtual drives
for d in "${drives[@]}"; do
  truncate -s ${drive_size} "${d}"
done

# create storage pool
pool_name=test_pool
mount_dir=test_mount
mkdir "${root_dir}/${mount_dir}/"
zpool create -m "${root_dir}/${mount_dir}/" ${pool_name} "${drives[@]}"

# create outfile
create_outfile

# time dataset creation
for i in ${dataset_steps[@]}; do
  new_d=$((${i}-${existing_datasets}))
  stdbuf --output=0 echo -e "\n* Increasing number of datasets by ${new_d} to next step, ${i}"
  increase_datasets_to ${i}
  measure_creation ${num_datasets_to_measure}
done

# Clean-up
# destroy storage pool
zpool destroy ${pool_name}

# delete virtual drive files and mount directory
for d in "${drives[@]}"; do
  rm "$d"
done

rmdir "${root_dir}/${mount_dir}"
