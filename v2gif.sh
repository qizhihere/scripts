#!/bin/bash
# video2giv in out width
# video2gif video_file_in.video gif_file_out.gif 300

tmp_dir=/tmp/frames_$(date +%s)
mkdir $tmp_dir

if [ -z "$3" ]
then
  size=600
else
  size=$3
fi

echo "Converting $1 => $2 ($size px wide)"
echo "Generating frames"

(ffmpeg -i $1 -vf scale=$size:-1 -r 10 $tmp_dir/ffout%03d.png) >& /dev/null

echo "Building gif from frames"

(convert -delay 5 -loop 0 $tmp_dir/ffout*.png $2) >& /dev/null

echo "Cleaning up"

rm -rf $tmp_dir
