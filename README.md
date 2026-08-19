# TTRPG LaTeX Library

A comprehensive LaTeX library for creating professional tabletop role-playing game (TTRPG) books and documents.

## Overview

This library provides a collection of LaTeX packages, styles, and Lua scripts designed to streamline the creation of TTRPG content. It includes utilities for data management, document formatting, and automated content processing.

## Components

### Core Style
- **ttrpg-core.sty**: Main style file providing the foundation for TTRPG document formatting

### TeX Modules
- **data-access.tex**: Data access and manipulation utilities
- **database.tex**: Database-like functionality for managing TTRPG content
- **handout.tex**: Handout document templates and formatting
- **print-helpers.tex**: Print optimization and helper functions

### Lua Scripts
- **bootstrap.lua**: Initialization and setup routines
- **ogl.lua**: Open Gaming License handling
- **parser.lua**: Content parsing utilities
- **scanner.lua**: Document scanning and processing
- **folder_counter.lua**: Automatic folder and section counting
- **xp.lua**: Experience point calculations and tables
- **utils.lua**: General utility functions

## Requirements

- LuaLaTeX (required for Lua script integration)
- Standard LaTeX packages (specific dependencies may vary by module)

## Usage

Include the core style file in your LaTeX document:

```latex
\usepackage{ttrpg-core}
```

Additional modules can be included as needed for specific functionality.

## Configuration

The `.latexmkrc` file provides build configuration for latexmk users.

## Purpose

This library was created to facilitate the production of custom TTRPG books, providing consistent formatting, automated content management, and specialized utilities for game design and publishing.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
