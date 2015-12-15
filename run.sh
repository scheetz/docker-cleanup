#!/bin/bash

if [ ! -e "/var/run/docker.sock" ]; then
    echo "=> Cannot find docker socket(/var/run/docker.sock), please check the command!"
    exit 1
fi

if docker version >/dev/null; then
    echo "docker is running properly"
else
    echo "Cannot run docker binary at /usr/bin/docker"
    echo "Please check if the docker binary is mounted correctly"
    exit 1
fi


if [ "${CLEAN_PERIOD}" == "**None**" ]; then
    echo "=> CLEAN_PERIOD not defined, use the default value."
    CLEAN_PERIOD=1800
fi

if [ "${DELAY_TIME}" == "**None**" ]; then
    echo "=> DELAY_TIME not defined, use the default value."
    DELAY_TIME=1800
fi

if [ "${KEEP_IMAGES}" == "**None**" ]; then
    unset KEEP_IMAGES
fi

echo "=> Run the clean script every ${CLEAN_PERIOD} seconds and delay ${DELAY_TIME} seconds to clean."

trap '{ echo "User Interupt."; exit 1; }' SIGINT
trap '{ echo "SIGTERM received, exiting."; exit 0; }' SIGTERM

# List candidate containers for removal
function listRemovalCandidates {
    cat <(docker ps -a -q -f 'status=created') <(docker ps -a -q -f 'label=com.meltwater.cleanup.removeme') | sort | uniq > "$1"
}

while [ 1 ]
do
    # Cleanup unused volumes
    /docker-cleanup-volumes.sh

    # Cleanup exited/dead containers
    EXITED_CONTAINERS_IDS="`docker ps -a -q -f status=exited -f status=dead | xargs echo`"
    if [ "$EXITED_CONTAINERS_IDS" != "" ]; then
        echo "Removing exited containers"
        docker rm -v $EXITED_CONTAINERS_IDS
    fi

    # Get all containers in "created" state or flagged to autoremove
    rm -f RemoveContainerIds
    listRemovalCandidates RemoveContainerIds

    # Get all image ID
    ALL_LAYER_NUM=$(docker images -a | tail -n +2 | wc -l)
    docker images -q --no-trunc | sort -o ImageIdList
    CONTAINER_ID_LIST=$(docker ps -aq --no-trunc)
    IFS='
    '
    # Get Image ID that is used by a containter
    rm -f ContainerImageIdList
    touch ContainerImageIdList
    for CONTAINER_ID in ${CONTAINER_ID_LIST}; do
        LINE=$(docker inspect ${CONTAINER_ID} | grep "\"Image\": \"[0-9a-fA-F]\{64\}\"")
        IMAGE_ID=$(echo ${LINE} | awk -F '"' '{print $4}')
        echo "${IMAGE_ID}" >> ContainerImageIdList
    done
    sort ContainerImageIdList -o ContainerImageIdList

    # Remove the images being used by cotnainers from the delete list
    comm -23 ImageIdList ContainerImageIdList > ToBeCleanedImageIdList

    # Remove those reserved images from the delete list
    if [ -n "${KEEP_IMAGES}" ]; then
        rm -f KeepImageIdList
        touch KeepImageIdList
        arr=$(echo ${KEEP_IMAGES} | tr "," "\n")
        for x in $arr
        do
            docker inspect $x | grep "\"Id\": \"[0-9a-fA-F]\{64\}\"" | head -1 | awk -F '"' '{print $4}'  >> KeepImageIdList
        done
        sort KeepImageIdList -o KeepImageIdList
        comm -23 ToBeCleanedImageIdList KeepImageIdList > ToBeCleanedImageIdList2
        mv ToBeCleanedImageIdList2 ToBeCleanedImageIdList
    fi

    # Wait before cleaning containers and images
    echo "=> Waiting ${DELAY_TIME} seconds before cleaning"
    sleep ${DELAY_TIME} & wait

    # Remove containers that haven't managed to start within the DELAY_TIME interval or those flagged to autoremove
    rm -f RemoveContainerIds2 RemoveContainers
    listRemovalCandidates RemoveContainerIds2
    comm -12 RemoveContainerIds RemoveContainerIds2 > RemoveContainers

    if [ -s RemoveContainers ]; then
        echo "=> Start to clean $(cat RemoveContainers | wc -l) stuck/autoclean containers"
        docker kill $(cat RemoveContainers)
        docker rm -v $(cat RemoveContainers)
    fi

    # Remove images being used by containers from the delete list again. This prevents the images being pulled from deleting
    CONTAINER_ID_LIST=$(docker ps -aq --no-trunc)
    rm -f ContainerImageIdList
    touch ContainerImageIdList
    for CONTAINER_ID in ${CONTAINER_ID_LIST}; do
        LINE=$(docker inspect ${CONTAINER_ID} | grep "\"Image\": \"[0-9a-fA-F]\{64\}\"")
        IMAGE_ID=$(echo ${LINE} | awk -F '"' '{print $4}')
        echo "${IMAGE_ID}" >> ContainerImageIdList
    done
    sort ContainerImageIdList -o ContainerImageIdList
    comm -23 ToBeCleanedImageIdList ContainerImageIdList > ToBeCleaned

    # Remove Images
    if [ -s ToBeCleaned ]; then
        echo "=> Start to clean $(cat ToBeCleaned | wc -l) images"
        docker rmi $(cat ToBeCleaned) 2>/dev/null
        (( DIFF_LAYER=${ALL_LAYER_NUM}- $(docker images -a | tail -n +2 | wc -l) ))
        (( DIFF_IMG=$(cat ImageIdList | wc -l) - $(docker images | tail -n +2 | wc -l) ))
        if [ ! ${DIFF_LAYER} -gt 0 ]; then
                DIFF_LAYER=0
        fi
        if [ ! ${DIFF_IMG} -gt 0 ]; then
                DIFF_IMG=0
        fi
        echo "=> Done! ${DIFF_IMG} images and ${DIFF_LAYER} layers have been cleaned."
    else
        echo "No images need to be cleaned"
    fi

    rm -f ToBeCleanedImageIdList ContainerImageIdList ToBeCleaned ImageIdList KeepImageIdList
    echo "=> Next clean will be started in ${CLEAN_PERIOD} seconds"
    sleep ${CLEAN_PERIOD} & wait
done
