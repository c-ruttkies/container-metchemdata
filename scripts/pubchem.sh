######
# pubchem filler script
######

# write a single pubchem entry as postgres query
write_pubchem_entry () {
 local line=$1
 local line=$(echo $line | sed "s/'//g" | sed "s/\"//g")
 local outfolder=$2
 # read values from argument string
 IFS='|' read -a vals <<< "$line"
 if [ "${vals[1]}" == "" ]; then return 1; fi
 if [ "${vals[2]}" == "" ]; then return 1; fi
 if [ "${vals[3]}" == "" ]; then return 1; fi
 if [ "${vals[4]}" == "" ]; then return 1; fi
 if [ "${vals[5]}" == "" ]; then return 1; fi
 if [ "${vals[6]}" == "" ]; then return 1; fi
 folder=$(echo ${vals[5]} | sed "s/\(..\)/\1\//g")
 if [ ! -e $outfolder/compound/$folder ]; then mkdir -p $outfolder/compound/$folder; fi
 local inchikey="${vals[5]}-${vals[6]}"
 if [ "${vals[7]}" != "" ]; then inchikey="${vals[5]}-${vals[6]}-${vals[7]}"; fi
 # insert pubchem entry
 echo "${vals[1]}|${vals[2]}|${vals[3]}|${vals[4]}|${vals[5]}|${vals[6]}|${vals[7]}|${inchikey}|${vals[8]}|${vals[0]}" >> $outfolder/compound/${folder}/${inchikey}
}

write_pubchem_entries () {
 local file=$1
 local library_id=$2
 currentcompoundid=$(/usr/bin/psql -c "SELECT max(compound_id) FROM compound;" -h $POSTGRES_IP -U $POSTGRES_USER -qtA -d $POSTGRES_DB)
 if [ "$currentcompoundid" == "" ]; then currentcompoundid=1; else currentcompoundid=$((currentcompoundid+1)); fi
 
 numlines=$(wc -l $file | cut -d" " -f1)
 # compound table
 paste -d"|" <(seq $currentcompoundid 1 $(expr $numlines + $currentcompoundid - 1)) <(cut -d"|" -f2,3,4,5,6,7,8,10 $file) | /usr/bin/psql -c "\COPY compound FROM STDIN ( FORMAT CSV, DELIMITER('|') );" -h  $POSTGRES_IP -U $POSTGRES_USER -d $POSTGRES_DB

 # substance table
 paste -d"|" <(seq $currentcompoundid 1 $(expr $numlines + $currentcompoundid - 1)) <(echo $(yes $library_id | head -n${numlines}) | tr ' ' '\n') <(seq $currentcompoundid 1 $(expr $numlines + $currentcompoundid - 1)) <(cut -d"|" -f1 $file) | /usr/bin/psql -c "\COPY substance FROM STDIN ( FORMAT CSV, DELIMITER('|') );" -h $POSTGRES_IP -U $POSTGRES_USER -d $POSTGRES_DB

 # name table
 paste -d"|" <(cut -d"|" -f9 $file) <(seq $currentcompoundid 1 $(expr $numlines + $currentcompoundid - 1)) | /usr/bin/psql -c "\COPY name FROM STDIN ( FORMAT CSV, DELIMITER('|') );" -h $POSTGRES_IP -U $POSTGRES_USER -d $POSTGRES_DB
}


# deletes from substance table NOT from compound table
delete_pubchem_entries () {
 filename=$1
 library_id=$2
 if [ ! -e /tmp/${filename}.sql ]
 then
  echo "Error in delete_pubchem_entries(): /tmp/${filename}.sql not found. Nothing to delete."
  return 1
 fi
 # get accession ranges from filename
 IFS=' ' read -a ranges <<< "$(echo $filename | sed "s/.*_0*\([0-9]*\)_0*\([0-9]*\)/\1 \2/")"
 # get accessions not included anymore
 # this is performed by comparison 
 comm -23 <(for (( c=${ranges[0]}; c<=${ranges[1]}; c++ )); do echo $c; done | sort) <(cut -d"|" -f1 /tmp/${filename}.sql | sort) > /tmp/${filename}.delete
 while read line
 do
   echo "delete from substance where accession='${line}' and library_id='${library_id}';" >> /tmp/${filename}.delete_query
 done < /tmp/${filename}.delete
 rm /tmp/${filename}.delete
 if [ -e /tmp/${filename}.delete_query ] 
 then
   # execute query file onto postgres server
   /usr/bin/psql -f /tmp/${filename}.delete_query -h $POSTGRES_IP -U $POSTGRES_USER -d $POSTGRES_DB > /dev/null
   rm /tmp/${filename}.delete_query
 fi
}

generate_pubchem_files() {
 echo "generate_pubchem_files"
 exists=$(/usr/bin/psql -c "select 1 from library where library_name='pubchem';" -h $POSTGRES_IP -U $POSTGRES_USER -qtA -d $POSTGRES_DB)
 if [ ! "$exists" == 1 ]
 then 
   echo "library pubchem does not exist"
   return 1
 fi
 library_id=$(/usr/bin/psql -c "SELECT library_id FROM library where library_name='pubchem';" -h $POSTGRES_IP -U $POSTGRES_USER -qtA -d $POSTGRES_DB)
 echo "library found -> $library_id"
 # check folders and clean
 echo "cleaning folders"
 if [ -e ${OUTPUT_FOLDER}/pubchem/ ]
 then 
  rm -rf ${OUTPUT_FOLDER}/pubchem/*
 fi
 mkdir -p ${OUTPUT_FOLDER}/pubchem/
 echo "downloading conversion tool"
 if [ ! -z ${PROXY+x} ]
 then
  wget -e use_proxy=yes -e http_proxy=$PROXY -q -O ~/ConvertSDF.jar http://www.rforrocks.de/wp-content/uploads/2012/10/ConvertSDF.jar
 else
  wget -q -O ~/ConvertSDF.jar http://www.rforrocks.de/wp-content/uploads/2012/10/ConvertSDF.jar
 fi
 # loop to check each data file
 if [ ! -e /data/${PUBCHEM_MIRROR} ]
 then
   echo "/data/${PUBCHEM_MIRROR} not found"
   exit 1       
 fi
 unset IFS
 if [ "$lastcompoundid" == "" ]; then lastcompoundid=0; fi
 for i in $(ls /data/${PUBCHEM_MIRROR} | grep -e "gz$")
 do
  echo "file ${i}"
  filename=$(echo $i | sed 's/\.sdf\.gz//')
  # unzip file
  gunzip -c -k /data/$PUBCHEM_MIRROR/$i > /tmp/${filename}.sdf
  # convert sdf to csv
  java -jar ~/ConvertSDF.jar sdf=/tmp/${filename}.sdf out=/tmp/ format=csv fast=true
  # write out values of specific columns
  paste -d"|" \
  <(awk -F '|' -v c="" 'NR==1{for(i=1;i<=NF;i++)n=$i~"PUBCHEM_COMPOUND_CID$"?i:n;next}n{print $n}' /tmp/${filename}.csv) \
  <(awk -F '|' -v c="" 'NR==1{for(i=1;i<=NF;i++)n=$i~"PUBCHEM_MONOISOTOPIC_WEIGHT$"?i:n;next}n{print $n}' /tmp/${filename}.csv) \
  <(awk -F '|' -v c="" 'NR==1{for(i=1;i<=NF;i++)n=$i~"PUBCHEM_MOLECULAR_FORMULA$"?i:n;next}n{print $n}' /tmp/${filename}.csv) \
  <(awk -F '|' -v c="" 'NR==1{for(i=1;i<=NF;i++)n=$i~"PUBCHEM_OPENEYE_CAN_SMILES$"?i:n;next}n{print $n}' /tmp/${filename}.csv) \
  <(awk -F '|' -v c="" 'NR==1{for(i=1;i<=NF;i++)n=$i~"PUBCHEM_IUPAC_INCHI$"?i:n;next}n{print $n}' /tmp/${filename}.csv) \
  <(awk -F '|' -v c="" 'NR==1{for(i=1;i<=NF;i++)n=$i~"PUBCHEM_IUPAC_INCHIKEY$"?i:n;next}n{print $n}' /tmp/${filename}.csv | sed "s/-/|/g") \
  <(awk -F '|' -v c="" 'NR==1{for(i=1;i<=NF;i++)n=$i~"PUBCHEM_IUPAC_OPENEYE_NAME$"?i:n;next}n{print $n}' /tmp/${filename}.csv) \
  <(awk -F '|' -v c="" 'NR==1{for(i=1;i<=NF;i++)n=$i~"PUBCHEM_IUPAC_INCHIKEY$"?i:n;next}n{print $n}' /tmp/${filename}.csv) \
  > /tmp/${filename}.sql
  # writes single insert command to query file
  write_pubchem_entries "/tmp/${filename}.sql" "${library_id}" > /dev/null
  # remove files
  rm /tmp/${filename}.sql
  rm /tmp/${filename}.sdf
  rm /tmp/${filename}.csv
 done
}
