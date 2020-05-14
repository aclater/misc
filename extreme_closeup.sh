#!/bin/bash
#
# using v4l2-ctl increment zoom every .25 seconds to 200% zoom
#

for i in {100..200} 
    do
        v4l2-ctl --set-ctrl zoom_absolute=$i
	sleep .005
    done

for i in {200..100} 
    do
        v4l2-ctl --set-ctrl zoom_absolute=$i
	sleep .005
    done


#
# reset zoom to 100%
#

v4l2-ctl --set-ctrl zoom_absolute=100
