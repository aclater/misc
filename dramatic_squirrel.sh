#!/bin/bash
#
# using v4l2-ctl increment zoom every .25 seconds to 200% zoom
#

for i in 100 120 130 140 150 160 170 180 190 200
    do
        v4l2-ctl --set-ctrl zoom_absolute=$i
        sleep .25
    done

sleep 1

#
# reset zoom to 100%
#

v4l2-ctl --set-ctrl zoom_absolute=100
