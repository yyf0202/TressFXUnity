﻿Shader "TressFX/Hair Rendering Shader"
{
    SubShader
    {
        Pass
        {
    		Tags { "LightMode" = "ForwardBase" }
        	Blend SrcAlpha OneMinusSrcAlpha // turn on alpha blending
        	ZWrite On
        	Cull Off
        	
            CGPROGRAM
            #pragma debug
            #pragma target 5.0
            #pragma multi_compile_fwdbase
            
            #pragma exclude_renderers gles
 
            #pragma vertex vert
            #pragma fragment frag
            #pragma geometry geom
            
            #include "UnityCG.cginc"
 
            //The buffer containing the points we want to draw.
            StructuredBuffer<float3> _VertexPositionBuffer;
            StructuredBuffer<int> _StrandIndicesBuffer;
            uniform float4 _HairColor;
            uniform float _HairThickness;
            uniform float4 _CameraDirection;
 
            //A simple input struct for our pixel shader step containing a position.
            struct ps_input {
                float4 pos : SV_POSITION;
                int vertexIndex : COLOR0;
            };
            
 
            //Our vertex function simply fetches a point from the buffer corresponding to the vertex index
            //which we transform with the view-projection matrix before passing to the pixel program.
            ps_input vert (uint id : SV_VertexID)
            {
                ps_input o;
                
                // Position transformation
                o.pos = mul (UNITY_MATRIX_VP, float4(_VertexPositionBuffer[id],1.0f));
                o.vertexIndex = id;
                
                return o;
            }

			[maxvertexcount(2)]
			void geom (line ps_input input[2], inout LineStream<ps_input> outStream)
			{
				outStream.Append(input[0]);
				if (_StrandIndicesBuffer[input[0].vertexIndex+1] == 0)
				{
					outStream.RestartStrip();
				}
				outStream.Append(input[1]);
			}
 
            //Pixel function returns a solid color for each point.
            float4 frag (ps_input i) : COLOR
            {
                return _HairColor;
            }
 
            ENDCG
 
        }
        // A-Buffer fill pass
        Pass
        {
    		Tags { "LightMode" = "ForwardBase" }
        	
            CGPROGRAM
            #pragma debug
            #pragma target 5.0
            
            #pragma exclude_renderers gles
 
            #pragma vertex vert
            #pragma fragment frag
            
            #include "UnityCG.cginc"
 
            //The buffer containing the points we want to draw.
            StructuredBuffer<float3> g_HairVertexTangents;
            StructuredBuffer<float3> g_HairVertexPositions;
            StructuredBuffer<int> g_TriangleIndicesBuffer;
            StructuredBuffer<float> g_HairThicknessCoeffs;

			//--------------------------------------------------------------------------------------
			// Per-Pixel Linked List (PPLL) structure
			//--------------------------------------------------------------------------------------
			struct PPLL_STRUCT
			{
			    uint	TangentAndCoverage;	
			    uint	depth;
			    uint    uNext;
			};
            
            // Configurations
            uniform float4 _HairColor;
            uniform float3 g_vEye;
            uniform float4 g_WinSize;
            uniform float g_FiberRadius;
            uniform float g_bExpandPixels;
            uniform float g_bThinTip;
            RWTexture2D<uint> LinkedListHeadUAV;
            RWStructuredBuffer<PPLL_STRUCT>	LinkedListUAV;
 
            //A simple input struct for our pixel shader step containing a position.
            struct PS_INPUT_HAIR_AA {
			    float4 Position	: SV_POSITION;
			    float4 Tangent	: Tangent;
			    float4 p0p1		: TEXCOORD0;
            };
            
 
            //Our vertex function simply fetches a point from the buffer corresponding to the vertex index
            //which we transform with the view-projection matrix before passing to the pixel program.
            PS_INPUT_HAIR_AA vert (uint id : SV_VertexID)
            {
            	uint vertexId = g_TriangleIndicesBuffer[id];
			    
			    // Access the current line segment
			    uint index = vertexId / 2;  // vertexId is actually the indexed vertex id when indexed triangles are used

			    // Get updated positions and tangents from simulation result
			    float3 t = g_HairVertexTangents[index].xyz;
			    float3 v = g_HairVertexPositions[index].xyz;

			    // Get hair strand thickness
			    float ratio = ( g_bThinTip > 0 ) ? g_HairThicknessCoeffs[index] : 1.0;

			    // Calculate right and projected right vectors
			    float3 right      = normalize( cross( t, normalize(v - g_vEye) ) );
			    float2 proj_right = normalize( mul( UNITY_MATRIX_VP, float4(right, 0) ).xy );

			    // g_bExpandPixels should be set to 0 at minimum from the CPU side; this would avoid the below test
			    float expandPixels = (g_bExpandPixels < 0 ) ? 0.0 : 0.71;

				// Calculate the negative and positive offset screenspace positions
				float4 hairEdgePositions[2]; // 0 is negative, 1 is positive
				hairEdgePositions[0] = float4(v +  -1.0 * right * ratio * g_FiberRadius, 1.0);
				hairEdgePositions[1] = float4(v +   1.0 * right * ratio * g_FiberRadius, 1.0);
				hairEdgePositions[0] = mul(UNITY_MATRIX_VP, hairEdgePositions[0]);
				hairEdgePositions[1] = mul(UNITY_MATRIX_VP, hairEdgePositions[1]);
				hairEdgePositions[0] = hairEdgePositions[0]/hairEdgePositions[0].w;
				hairEdgePositions[1] = hairEdgePositions[1]/hairEdgePositions[1].w;

			    // Write output data
			    PS_INPUT_HAIR_AA Output = (PS_INPUT_HAIR_AA)0;
			    float fDirIndex = (vertexId & 0x01) ? -1.0 : 1.0;
			    Output.Position = (fDirIndex==-1.0 ? hairEdgePositions[0] : hairEdgePositions[1]) + fDirIndex * float4(proj_right * expandPixels / g_WinSize.y, 0.0f, 0.0f);
			    Output.Tangent  = float4(t, ratio);
			    Output.p0p1     = float4( hairEdgePositions[0].xy, hairEdgePositions[1].xy );

			    return Output;
            }
			
			// Helper functions
			//--------------------------------------------------------------------------------------
			// ComputeCoverage
			//
			// Calculate the pixel coverage of a hair strand by computing the hair width
			//--------------------------------------------------------------------------------------
			float ComputeCoverage(float2 p0, float2 p1, float2 pixelLoc)
			{
				// p0, p1, pixelLoc are in d3d clip space (-1 to 1)x(-1 to 1)

				// Scale positions so 1.f = half pixel width
				p0 *= g_WinSize.xy;
				p1 *= g_WinSize.xy;
				pixelLoc *= g_WinSize.xy;

				float p0dist = length(p0 - pixelLoc);
				float p1dist = length(p1 - pixelLoc);
				float hairWidth = length(p0 - p1);
			    
				// will be 1.f if pixel outside hair, 0.f if pixel inside hair
				float outside = any( float2(step(hairWidth, p0dist), step(hairWidth, p1dist)) );
				
				// if outside, set sign to -1, else set sign to 1
				float sign = outside > 0.f ? -1.f : 1.f;
				
				// signed distance (positive if inside hair, negative if outside hair)
				float relDist = sign * saturate( min(p0dist, p1dist) );
				
				// returns coverage based on the relative distance
				// 0, if completely outside hair edge
				// 1, if completely inside hair edge
				return (relDist + 1.f) * 0.5f;
			}

			//--------------------------------------------------------------------------------------
			// ComputeShadow
			//
			// Computes the shadow using a simplified deep shadow map technique for the hair and
			// PCF for scene objects. It uses multiple taps to filter over a (KERNEL_SIZE x KERNEL_SIZE)
			// kernel for high quality results.
			//--------------------------------------------------------------------------------------
			/*float ComputeShadow(float3 worldPos, float alpha, int iTechSM)
			{

				if( iTechSM == SHADOW_NONE )
					return 1;

				float4 projPosLight = mul(float4(worldPos,1), g_mViewProjLight);
				float2 texSM = float2(projPosLight.x/projPosLight.w+1, -projPosLight.y/projPosLight.w+1)*0.5;
				float depth = projPosLight.z/projPosLight.w;
				float epsilon = depth * SM_EPSILON;
				float depth_fragment = projPosLight.w;

				// for shadow casted by scene objs, use PCF shadow
				float total_weight = 0;
				float amountLight_hair = 0;	

				total_weight = 0;
				[unroll] for (int dx = (1-KERNEL_SIZE)/2; dx <= KERNEL_SIZE/2; dx++) 
				{ 
					[unroll] for (int dy = (1-KERNEL_SIZE)/2; dy <= KERNEL_SIZE/2; dy++) 
					{ 
						float size = 2.4;
						float sigma = (KERNEL_SIZE/2.0)/size; // standard deviation, when kernel/2 > 3*sigma, it's close to zero, here we use 1.5 instead
						float exp = -1* (dx*dx + dy*dy)/ (2* sigma * sigma);
						float weight = 1/(2*PI*sigma*sigma) * pow(e, exp);

						// shadow casted by hair: simplified deep shadow map
						float depthSMHair = g_txSMHair.SampleLevel( g_samPointClamp, texSM, 0, int2(dx, dy) ).x; //z/w

						float depth_smPoint = g_fNearLight/(1 - depthSMHair*(g_fFarLight - g_fNearLight)/g_fFarLight);

						float depth_range = max(0, depth_fragment-depth_smPoint); 
						float numFibers =  depth_range/(g_FiberSpacing*g_FiberRadius);

						// if occluded by hair, there is at least one fiber
						[flatten]if (depth_range > 1e-5)
							numFibers += 1;
						amountLight_hair += pow(abs(1-alpha), numFibers)*weight;

						total_weight += weight;
					}
				}
				amountLight_hair /= total_weight;

				float amountLight_scene = g_txSMScene.SampleCmpLevelZero(g_samShadow, texSM, depth-epsilon);

				return (amountLight_hair * amountLight_scene);

			}

			//--------------------------------------------------------------------------------------
			// ComputeSimpleShadow
			//
			// Computes the shadow using a simplified deep shadow map technique for the hair and
			// PCF for scene objects. This function only uses one sample, so it is faster but
			// not as good quality as ComputeShadow
			//--------------------------------------------------------------------------------------
			float ComputeSimpleShadow(float3 worldPos, float alpha, int iTechSM)
			{
				if( iTechSM == SHADOW_NONE )
				{
					return 1;
				}

				float4 projPosLight = mul(float4(worldPos,1), g_mViewProjLight);

				float2 texSM = 0.5 * float2(projPosLight.x/projPosLight.w+1.0, -projPosLight.y/projPosLight.w+1.0);
				float depth = projPosLight.z/projPosLight.w;
				float epsilon = depth * SM_EPSILON;
				float depth_fragment = projPosLight.w;

				// shadow casted by scene
				float amountLight_scene = g_txSMScene.SampleCmpLevelZero(g_samShadow, texSM, depth-epsilon);

				// shadow casted by hair: simplified deep shadow map
				float depthSMHair = g_txSMHair.SampleLevel( g_samPointClamp, texSM, 0 ).x; //z/w

				float depth_smPoint = g_fNearLight/(1 - depthSMHair*(g_fFarLight - g_fNearLight)/g_fFarLight);

				float depth_range = max(0, depth_fragment-depth_smPoint); 
				float numFibers =  depth_range/(g_FiberSpacing*g_FiberRadius);

				// if occluded by hair, there is at least one fiber
			    [flatten]if (depth_range > 1e-5)
					numFibers += 1.0;
				float amountLight_hair = pow(abs(1-alpha), numFibers);

				return amountLight_scene * amountLight_hair;
			}*/
			
			void StoreFragments_Hair(uint2 address, float3 tangent, float coverage, float depth)
			{
			    // Retrieve current pixel count and increase counter
			    uint uPixelCount = LinkedListUAV.IncrementCounter();
			    uint uOldStartOffset;

			    // Exchange indices in LinkedListHead texture corresponding to pixel location 
			    InterlockedExchange(LinkedListHeadUAV[address], uPixelCount, uOldStartOffset);  // link head texture

			    // Append new element at the end of the Fragment and Link Buffer
			    PPLL_STRUCT Element;
				Element.TangentAndCoverage = PackTangentAndCoverage(tangent, coverage);
				Element.depth = asuint(depth);
			    Element.uNext = uOldStartOffset;
			    LinkedListUAV[uPixelCount] = Element; // buffer that stores the fragments
			}
			
			uint PackFloat4IntoUint(float4 vValue)
			{
			    return ( (uint(vValue.x*255)& 0xFFUL) << 24 ) | ( (uint(vValue.y*255)& 0xFFUL) << 16 ) | ( (uint(vValue.z*255)& 0xFFUL) << 8) | (uint(vValue.w * 255)& 0xFFUL);
			}

			float4 UnpackUintIntoFloat4(uint uValue)
			{
			    return float4( ( (uValue & 0xFF000000)>>24 ) / 255.0, ( (uValue & 0x00FF0000)>>16 ) / 255.0, ( (uValue & 0x0000FF00)>>8 ) / 255.0, ( (uValue & 0x000000FF) ) / 255.0);
			}

			uint PackTangentAndCoverage(float3 tangent, float coverage)
			{
			    return PackFloat4IntoUint( float4(tangent.xyz*0.5 + 0.5, coverage) );
			}

			float3 GetTangent(uint packedTangent)
			{
			    return 2.0 * UnpackUintIntoFloat4(packedTangent).xyz - 1.0;
			}

			float GetCoverage(uint packedCoverage)
			{
			    return UnpackUintIntoFloat4(packedCoverage).w;
			}
            
            // A-Buffer pass
            float4 frag( PS_INPUT_HAIR_AA In) : SV_Target
			{ 
			    // Render AA Line, calculate pixel coverage
			    float4 proj_pos = float4(   2*In.Position.x*g_WinSize.z - 1.0,  // g_WinSize.z = 1.0/g_WinSize.x
			                                1 - 2*In.Position.y*g_WinSize.w,    // g_WinSize.w = 1.0/g_WinSize.y 
			                                1, 
			                                1);

			    float4 original_pos = mul(proj_pos, g_mInvViewProj);
			    
			    float curve_scale = 1;
			    if (g_bThinTip > 0 )
			        curve_scale = In.Tangent.w;
			    
			    float fiber_radius = curve_scale * g_FiberRadius;
				
				float coverage = 1.f;
				if(g_bUseCoverage)
				{	
			        coverage = ComputeCoverage(In.p0p1.xy, In.p0p1.zw, proj_pos.xy);
				}

				coverage *= g_FiberAlpha;

			    // only store fragments with non-zero alpha value
			    if (coverage > g_alphaThreshold) // ensure alpha is at least as much as the minimum alpha value
			    {
			        StoreFragments_Hair(In.Position.xy, In.Tangent.xyz, coverage, In.Position.z);
			    }
			    // output a mask RT for final pass    
			    return float4(1, 0, 0, 0);
			}
 
            //Pixel function returns a solid color for each point.
            float4 frag2 (PS_INPUT_HAIR_AA i) : COLOR
            {
                return _HairColor;
            }
            
            ENDCG
        }
    }
 
    Fallback Off
}