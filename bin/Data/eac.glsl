#version 430 core

// Ballot & group vote are both used as optimization (both must be present or none)
// We have a fallback path if it's not supported
#extension GL_ARB_shader_ballot : enable
#extension GL_ARB_shader_group_vote : enable

#ifdef GL_ARB_shader_ballot
#	ifdef GL_ARB_shader_group_vote
#		define WARP_SYNC_AVAILABLE
#	endif
#endif

// #include "/media/matias/Datos/SyntaxHighlightingMisc.h"

#include "CrossPlatformSettings_piece_all.glsl"
#include "UavCrossPlatform_piece_all.glsl"

#define FLT_MAX 340282346638528859811704183484516925440.0f

#define PotentialSolution uint

// Define this to use the compressor to generate data for R11 (or RG11)
// Without defining this, the compressor generates data for ETC2_Alpha
// It's almost the same but the differences are subtle
// (they differ on how multiplier = 0 is handled. ETC2_Alpha just forbids it)
//#define R11_EAC

#ifdef R11_EAC
#	define EAC_FETCH_SWIZZLE r
#	define EAC_RANGE 2047.0f
#	define EAC_MULTIPLIER_START 0u
#else
#	define EAC_FETCH_SWIZZLE a
#	define EAC_RANGE 255.0f
#	define EAC_MULTIPLIER_START 1u
#endif

PotentialSolution storePotentialSolution( const float baseCodeword, const int tableIdx,
										  const float multiplier )
{
	return packUnorm4x8( float4( baseCodeword, float( tableIdx ), multiplier, 0.0f ) *
						 ( 1.0f / 255.0f ) );
}

void loadPotentialSolution( PotentialSolution potentialSolution, out float baseCodeword,
							out uint tableIdx, out float multiplier )
{
	const float4 val = unpackUnorm4x8( potentialSolution );
	baseCodeword = val.x * 255.0f;
	tableIdx = uint( val.y * 255.0f );
	multiplier = val.z * 255.0f;
}

// For alpha support
const float kEacModifiers[16][8] = { { -3, -6, -9, -15, 2, 5, 8, 14 }, { -3, -7, -10, -13, 2, 6, 9, 12 },
									 { -2, -5, -8, -13, 1, 4, 7, 12 }, { -2, -4, -6, -13, 1, 3, 5, 12 },
									 { -3, -6, -8, -12, 2, 5, 7, 11 }, { -3, -7, -9, -11, 2, 6, 8, 10 },
									 { -4, -7, -8, -11, 3, 6, 7, 10 }, { -3, -5, -8, -11, 2, 4, 7, 10 },
									 { -2, -6, -8, -10, 1, 5, 7, 9 },  { -2, -5, -8, -10, 1, 4, 7, 9 },
									 { -2, -4, -8, -10, 1, 3, 7, 9 },  { -2, -5, -7, -10, 1, 4, 6, 9 },
									 { -3, -4, -7, -10, 2, 3, 6, 9 },  { -1, -2, -3, -10, 0, 1, 2, 9 },
									 { -4, -6, -8, -9, 3, 5, 7, 8 },   { -3, -5, -7, -9, 2, 4, 6, 8 } };

// 2 sets of 16 float3 (rgba8_unorm) for each ETC block
// We use rgba8_unorm encoding because it's 6kb vs 1.5kb of LDS. The former kills occupancy
shared float g_srcPixelsBlock[16];
shared PotentialSolution g_bestSolution[256];
shared float g_bestError[256];
shared bool g_allPixelsEqual;

uniform sampler2D srcTex;

layout( rg32ui ) uniform restrict writeonly uimage2D dstTexture;

layout( local_size_x = 256,  //
		local_size_y = 1,    //
		local_size_z = 1 ) in;

float calcError( float3 a, float3 b )
{
	float3 diff = a - b;
	return dot( diff, diff );
}

float eac_find_best_error( const float baseCodeword, float multiplier, const int tableIdx )
{
	float accumError = 0.0f;

	multiplier = multiplier > 0.0f ? multiplier * 8.0f : 1.0f;

	for( int i = 0; i < 16; ++i )
	{
		const float realV = g_srcPixelsBlock[i];
		float bestError = FLT_MAX;

		// Find modifier index through brute force
		for( int j = 0; j < 8 && bestError > 0; ++j )
		{
			const float tryValue =
				clamp( baseCodeword + kEacModifiers[tableIdx][j] * multiplier, 0.0f, EAC_RANGE );
			const float error = abs( realV - tryValue );
			if( error < bestError )
				bestError = error;
		}

		accumError += bestError * bestError;
	}

	return accumError;
}

void eac_pack( const float baseCodeword, float multiplier, const uint tableIdx )
{
	const uint iMultiplier = uint( multiplier );

#ifdef R11_EAC
	multiplier = multiplier > 0.0f ? multiplier * 8.0f : 1.0f;
#endif

	uint bestIdx[16];

	for( int i = 0; i < 16; ++i )
	{
		const float realV = g_srcPixelsBlock[i];
		float bestError = FLT_MAX;

		// Find modifier index through brute force
		for( uint j = 0u; j < 8u && bestError > 0; ++j )
		{
			const float tryValue = baseCodeword + kEacModifiers[tableIdx][j] * multiplier;
			const float error = abs( realV - tryValue );
			if( error < bestError )
			{
				bestError = error;
				bestIdx[i] = j;
			}
		}
	}

	uint2 outputBytes;

	outputBytes.x = uint( baseCodeword ) | ( tableIdx << 4u ) | ( iMultiplier << 8u ) |  //
					( bestIdx[0] << 12u ) | ( bestIdx[1] << 15u ) | ( bestIdx[2] << 18u ) |
					( bestIdx[3] << 21u ) | ( bestIdx[4] << 24u ) | ( bestIdx[5] << 27u ) |
					( bestIdx[6] << 30u );
	outputBytes.y = ( bestIdx[6] >> 1u ) | ( bestIdx[7] << 4u ) | ( bestIdx[8] << 7u ) |
					( bestIdx[9] << 10u ) | ( bestIdx[10] << 13u ) | ( bestIdx[11] << 16u ) |
					( bestIdx[12] << 19u ) | ( bestIdx[13] << 22u ) | ( bestIdx[14] << 25u ) |
					( bestIdx[15] << 28u );

	const uint2 dstUV = gl_WorkGroupID.xy;
	imageStore( dstTexture, int2( dstUV ), uint4( outputBytes.xy, 0u, 0u ) );
}

void main()
{
	// We perform a brute force search:
	//
	//	256 base codewords
	//	16 table indices
	//	16 multipliers
	//	8 possible indices per pixel (16 pixels)
	//
	//	That means we have to try 256*16*16*(8*16) = 8.388.608 variations per block
	const uint baseCodeword = gl_LocalInvocationID.x;

	// Load all pixels. We have 256 threads so have the first 16 load 1 pixel each
	if( baseCodeword < 16u )
	{
		uint2 pixelToLoad = gl_WorkGroupID.xy << 2u;
		// Note EAC wants the src pixels transposed!
		pixelToLoad.x += baseCodeword >> 2u;    //+= baseCodeword / 4
		pixelToLoad.y += baseCodeword & 0x03u;  //+= baseCodeword % 4
		const float srcPixel = OGRE_Load2D( srcTex, int2( pixelToLoad ), 0 ).EAC_FETCH_SWIZZLE;

#ifdef WARP_SYNC_AVAILABLE
		if( gl_SubGroupSizeARB >= 16u )
		{
			// Check if all pixels are equal (when wavefront optimizations are possible)
			const bool bSameValue = readFirstInvocationARB( srcPixel ) == srcPixel;
			const bool allPixelsEqual = allInvocationsARB( bSameValue );

			if( baseCodeword == 0u )
				g_allPixelsEqual = allPixelsEqual;
		}
#endif

		g_srcPixelsBlock[baseCodeword] = srcPixel * EAC_RANGE;
	}

#ifdef WARP_SYNC_AVAILABLE
	if( gl_SubGroupSizeARB < 16u )
#endif
	{
		// Fallback path when shader ballot cannot be used (wavefront size too small)
		// Check if all pixels are equal
		__sharedOnlyBarrier;

		bool allPixelsEqual = true;
		for( uint i = 1u; i < 16u; ++i )
		{
			if( g_srcPixelsBlock[0] != g_srcPixelsBlock[i] )
				allPixelsEqual = false;
		}
		g_allPixelsEqual = allPixelsEqual;
	}

	__sharedOnlyBarrier;

	if( g_allPixelsEqual )
	{
		uint2 outputBytes;
		outputBytes.x = baseCodeword;
		outputBytes.y = 0u;
		const uint2 dstUV = gl_WorkGroupID.xy;
		imageStore( dstTexture, int2( dstUV ), uint4( outputBytes.xy, 0u, 0u ) );
	}
	else
	{
		float bestError = FLT_MAX;
		PotentialSolution bestSolution = 0u;
		const float fBaseCodeword = float( baseCodeword );

		for( int tableIdx = 0; tableIdx < 16; ++tableIdx )
		{
			for( float multiplier = EAC_MULTIPLIER_START; multiplier < 16; ++multiplier )
			{
				const float error = eac_find_best_error( fBaseCodeword, multiplier, tableIdx );
				if( error < bestError )
				{
					bestError = error;
					bestSolution = storePotentialSolution( fBaseCodeword, tableIdx, multiplier );
				}
			}
		}

		g_bestSolution[baseCodeword] = bestSolution;

		__sharedOnlyBarrier;

		// Parallel reduction to find the best solution
		uint iterations = 8u;  // 256 threads = 256 reductions = 2⁸ -> 8 iterations
		for( uint i = 0u; i < iterations; ++i )
		{
			const uint mask = ( 1u << ( i + 1u ) ) - 1u;
			const uint idx = 1u << i;
			if( ( baseCodeword & mask ) == 0u )
			{
				if( g_bestError[baseCodeword + idx] < bestError )
				{
					g_bestError[baseCodeword] = g_bestError[baseCodeword + idx];
					g_bestSolution[baseCodeword] = g_bestSolution[baseCodeword + idx];
				}
			}
		}

		if( baseCodeword == 0u )
		{
			float bestBaseCodeword, bestMultiplier;
			uint bestTableIdx;
			loadPotentialSolution( g_bestSolution[0u], bestBaseCodeword, bestTableIdx, bestMultiplier );
			eac_pack( bestBaseCodeword, bestMultiplier, bestTableIdx );
		}
	}
}
