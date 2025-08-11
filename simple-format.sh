#!/bin/bash

# Simple trace formatter that replaces XSL with a basic sed/awk approach
# This is much simpler than the complex XSL or Zig implementation

cat | sed '
    # Strip XML declaration and logging line
    1,2d
    
    # Convert span tags to arrows with proper indentation
    s|^[[:space:]]*<span>|▶|
    s|^[[:space:]]*</span>||
    
    # Convert info tags
    s|^[[:space:]]*<info>\([^<]*\)</info>|\1|
    
    # Convert decisions to lightning bolts
    s|^[[:space:]]*<decision>\([^<]*\)</decision>|  ⚡ \1|
    
    # Convert simple data groups to compact format
    s|^[[:space:]]*<data label="\([^"]*\)">|🔸 \1(|
    s|^[[:space:]]*</data>|)|
    
    # Convert simple items
    s|^[[:space:]]*<item key="\([^"]*\)">\([^<]*\)</item>|\1: \2|
    
    # Remove empty lines
    /^[[:space:]]*$/d
    
    # Add proper indentation
    # TODO: This needs more work for proper nesting
' 