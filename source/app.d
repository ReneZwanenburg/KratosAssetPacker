import std.stdio;
import std.exception;
import std.file;
import std.algorithm;
import std.conv;
import std.digest.md;
import std.path;
import std.array;

struct FileInfo
{
	ubyte[digestLength!MD5]	hash;
	ulong					startOffset;
	ulong					endOffset;
}

void main(string[] args)
{
	enforce(args.length == 3, "Usage: AssetPacker assetdir packfile");
	
	auto assetPath = absolutePath(args[1]);
	auto assets = 
		dirEntries(assetPath, SpanMode.depth)
		.filter!(a => a.isFile).array;
	
	auto outFile = File(args[2], "w");
	
	uint numAssets = assets.count().to!uint;
	outFile.rawWrite([numAssets]);
	
	ulong currentOffset = numAssets.sizeof + numAssets * FileInfo.sizeof;
	foreach(asset; assets)
	{
		auto nextOffset = currentOffset + asset.size;
		auto path = relativePath(asset.name, assetPath);
		auto info = FileInfo(md5Of(path), currentOffset, nextOffset);
		
		writefln("%s -> %(%X%), offset: %s, size: %s", path, info.hash[], currentOffset, asset.size);
		
		outFile.rawWrite([info]);
		currentOffset = nextOffset;
	}
	
	writeln("Copying assets to pack...");
	
	foreach(asset; assets)
	{
		foreach(chunk; File(asset.name).byChunk(128 * 1024))
		{
			outFile.rawWrite(chunk);
		}
	}
	
	writeln("Asset pack creation successful");
}