#!/bin/bash

echo "Starting turbostat monitoring..."
# Start turbostat in the background (write output to a file)
turbostat -o /mnt/data/turbostat_output.txt;
