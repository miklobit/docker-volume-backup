#!/bin/bash

# Cronjobs don't inherit their env, so load from file
source env.sh

function info {
  bold="\033[1m"
  reset="\033[0m"
  echo -e "\n$bold[INFO] $1$reset\n"
}

info "Backup starting"
TIME_START="$(date +%s.%N)"
DOCKER_SOCK="/var/run/docker.sock"
if [ -S "$DOCKER_SOCK" ]; then
  TEMPFILE_CONTAINERS="$(mktemp)"
  docker ps --format "{{.ID}}" --filter "label=docker-volume-backup.stop-during-backup=true" > "$TEMPFILE_CONTAINERS"
  CONTAINERS_TO_STOP="$(cat $TEMPFILE_CONTAINERS | tr '\n' ' ')"
  CONTAINERS_TO_STOP_TOTAL="$(cat $TEMPFILE_CONTAINERS | wc -l)"
  CONTAINERS_TOTAL="$(docker ps --format "{{.ID}}" | wc -l)"
  rm "$TEMPFILE_CONTAINERS"
  echo "$CONTAINERS_TOTAL containers running on host in total"
  echo "$CONTAINERS_TO_STOP_TOTAL containers marked to be stopped during backup"
  
  TEMPFILE_SERVICES="$(mktemp)"
  docker service ls --format "{{.ID}}" --filter "label=docker-volume-backup.stop-during-backup=true" > "$TEMPFILE_SERVICES"
  SERVICES_TO_DOWN=$(cat  $TEMPFILE_SERVICES | awk '{print}' ORS='=0 ')
  SERVICES_TO_UP=$(cat  $TEMPFILE_SERVICES | awk '{print}' ORS='=1 ')
  SERVICES_TO_DOWN_TOTAL="$(cat $TEMPFILE_SERVICES | wc -l)"
  SERVICES_TOTAL="$(docker service ls --format "{{.ID}}" | wc -l)"
  rm "$TEMPFILE_SERVICES"
  echo "$SERVICES_TOTAL services running on host in total"
  echo "$SERVICES_TO_DOWN_TOTAL services marked to down during backup"  
else
  CONTAINERS_TO_STOP_TOTAL="0"
  CONTAINERS_TOTAL="0"
  SERVICES_TO_DOWN_TOTAL="0"
  SERVICES_TOTAL="0"  
  echo "Cannot access \"$DOCKER_SOCK\", won't look for containers to stop and/or services to down"
fi


if [ -S "$DOCKER_SOCK" ]; then
# [command in service label]  
  TEMPFILE_SERVICES="$(mktemp)"
  docker service ls \
    --filter "label=docker-volume-backup.exec-pre-backup" \
    --format '{{.ID}}' | \
        xargs docker service inspect \
             --format='{{ range $k, $v := .Spec.Labels }}{{- if eq $k "docker-volume-backup.exec-pre-backup" -}}{{$v}}{{end}}{{end}}'  \
    > "$TEMPFILE_SERVICES"
  info "Pre-exec command(s) (services)"
  cat "$TEMPFILE_SERVICES"
  chmod u+x "$TEMPFILE_SERVICES" 
  "$TEMPFILE_SERVICES"
  rm "$TEMPFILE_SERVICES" 
fi


if [ "$CONTAINERS_TO_STOP_TOTAL" != "0" ]; then
  info "Stopping containers"
  docker stop $CONTAINERS_TO_STOP
fi

if [ "$SERVICES_TO_DOWN_TOTAL" != "0" ]; then
  info "Scaling down services"
  docker service scale $SERVICES_TO_DOWN
fi

if [ -S "$DOCKER_SOCK" ]; then
# docker exec container_ID [command in container label]
  TEMPFILE_CONTAINERS="$(mktemp)"
  docker ps \
    --filter "label=docker-volume-backup.exec-pre-backup" \
    --format '{{.ID}} {{.Label "docker-volume-backup.exec-pre-backup"}}' \
    > "$TEMPFILE_CONTAINERS"
  while read line; do
    info "Pre-exec command (containers): $line"
    docker exec $line
  done < "$TEMPFILE_CONTAINERS"
  rm "$TEMPFILE_CONTAINERS"
  
fi

info "Creating backup"
TIME_BACK_UP="$(date +%s.%N)"
tar -czvf "$BACKUP_FILENAME" $BACKUP_SOURCES # allow the var to expand, in case we have multiple sources
BACKUP_SIZE="$(du --bytes $BACKUP_FILENAME | sed 's/\s.*$//')"
TIME_BACKED_UP="$(date +%s.%N)"

if [ -S "$DOCKER_SOCK" ]; then
# docker exec container_ID [command in container label]
  TEMPFILE_CONTAINERS="$(mktemp)"
  docker ps \
    --filter "label=docker-volume-backup.exec-post-backup" \
    --format '{{.ID}} {{.Label "docker-volume-backup.exec-post-backup"}}' \
    > "$TEMPFILE_CONTAINERS"
  while read line; do
    info "Post-exec command (containers): $line"
    docker exec $line
  done < "$TEMPFILE_CONTAINERS"
  rm "$TEMPFILE_CONTAINERS"

fi

if [ "$CONTAINERS_TO_STOP_TOTAL" != "0" ]; then
  info "Starting containers back up"
  docker start $CONTAINERS_TO_STOP
fi

if [ "$SERVICES_TO_DOWN_TOTAL" != "0" ]; then
  info "Scaling up services"
  docker service scale $SERVICES_TO_UP
fi

if [ -S "$DOCKER_SOCK" ]; then
# [command in service label]    
  TEMPFILE_SERVICES="$(mktemp)"
  docker service ls \
    --filter "label=docker-volume-backup.exec-post-backup" \
    --format '{{.ID}}' | \
        xargs docker service inspect \
             --format='{{ range $k, $v := .Spec.Labels }}{{- if eq $k "docker-volume-backup.exec-post-backup" -}}{{$v}}{{end}}{{end}}'  \
    > "$TEMPFILE_SERVICES"
  info "Post-exec command(s) (services)"
  cat "$TEMPFILE_SERVICES"
  chmod u+x "$TEMPFILE_SERVICES" 
  "$TEMPFILE_SERVICES"
  rm "$TEMPFILE_SERVICES"  
fi


info "Waiting before processing"
echo "Sleeping $BACKUP_WAIT_SECONDS seconds..."
sleep "$BACKUP_WAIT_SECONDS"

TIME_UPLOAD="0"
TIME_UPLOADED="0"
if [ ! -z "$AWS_S3_BUCKET_NAME" ]; then
  info "Uploading backup to S3"
  echo "Will upload to bucket \"$AWS_S3_BUCKET_NAME\""
  TIME_UPLOAD="$(date +%s.%N)"
  aws s3 cp --only-show-errors "$BACKUP_FILENAME" "s3://$AWS_S3_BUCKET_NAME/"
  echo "Upload finished"
  TIME_UPLOADED="$(date +%s.%N)"
fi

if [ -d "$BACKUP_ARCHIVE" ]; then
  info "Archiving backup"
  mv -v "$BACKUP_FILENAME" "$BACKUP_ARCHIVE/$BACKUP_FILENAME"
fi

if [ -f "$BACKUP_FILENAME" ]; then
  info "Cleaning up"
  rm -vf "$BACKUP_FILENAME"
fi

info "Collecting metrics"
TIME_FINISH="$(date +%s.%N)"
INFLUX_LINE="$INFLUXDB_MEASUREMENT\
,host=$BACKUP_HOSTNAME\
\
 size_compressed_bytes=$BACKUP_SIZE\
,containers_total=$CONTAINERS_TOTAL\
,containers_stopped=$CONTAINERS_TO_STOP_TOTAL\
,services_total=$SERVICES_TOTAL\
,services_scaled_down=$SERVICES_TO_DOWN_TOTAL\
,time_wall=$(perl -E "say $TIME_FINISH - $TIME_START")\
,time_total=$(perl -E "say $TIME_FINISH - $TIME_START - $BACKUP_WAIT_SECONDS")\
,time_compress=$(perl -E "say $TIME_BACKED_UP - $TIME_BACK_UP")\
,time_upload=$(perl -E "say $TIME_UPLOADED - $TIME_UPLOAD")\
"
echo "$INFLUX_LINE" | sed 's/ /,/g' | tr , '\n'

if [ ! -z "$INFLUXDB_URL" ]; then
  info "Shipping metrics"
  curl \
    --silent \
    --include \
    --request POST \
    --user "$INFLUXDB_CREDENTIALS" \
    "$INFLUXDB_URL/write?db=$INFLUXDB_DB" \
    --data-binary "$INFLUX_LINE"
fi

info "Backup finished"
echo "Will wait for next scheduled backup"
