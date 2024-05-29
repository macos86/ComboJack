#!/bin/bash
cd `dirname $0`

xcodebuild clean

xcodebuild -configuration Release || exit 1

