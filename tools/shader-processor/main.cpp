#include <cstdlib>
#include <iostream>
#include <fstream>
#include <string_view>
#include <algorithm>
#include "IncludeParser.h"

inline void writeString(std::ofstream &fout, std::string_view str)
{
  fout.write(str.data(), str.size());
}

int main(int argc, char **argv)
{
  if (argc != 3)
  {
    std::cerr << "Expected 2 arguments!" << std::endl;
    return EXIT_FAILURE;
  }

  betsy::IncludeParser parser;
  if (!parser.loadFromFile(argv[1]))
  {
    std::cerr << "Failed to load input: " << argv[1] << std::endl;
    return EXIT_FAILURE;
  }

  std::filesystem::path outPath = argv[2];
  std::ofstream fout(outPath);

  if (fout.fail())
  {
    std::cerr << "Failed to open output: " << argv[2] << std::endl;
    return EXIT_FAILURE;
  }

  auto identifier = outPath.stem().string();
  std::replace(identifier.begin(), identifier.end(), '.', '_'); // replace all 'x' to 'y'
  std::replace(identifier.begin(), identifier.end(), '-', '_'); // replace all 'x' to 'y'

  writeString(fout, "// Generated by shader-processor. DO NOT TOUCH\n");
  writeString(fout, std::string("const char* ") + identifier + " = R\"(\n");
  writeString(fout, parser.getFinalSource());
  writeString(fout, ")\";");

  return EXIT_SUCCESS;
}