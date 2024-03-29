#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include <helper_cuda.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
//#include "stdafx.h"
#include <ctime>
#include <sstream>
#include <stdio.h>
#include <iostream>
#include <iomanip>      // std::setfill, std::setw
#include <array>
//#include "cutil.h"

using namespace std;


/*
This file can be downloaded from supercomputingblog.com.
This is part of a series of tutorials that demonstrate how to use CUDA
The tutorials will also demonstrate the speed of using CUDA
*/

// IMPORTANT NOTE: for this data size, your graphics card should have at least 256 megabytes of memory.
// If your GPU has less memory, then you will need to decrease this data size.

#define MAX_DATA_SIZE		1024*1024*8		// about 16 million elements. 
// The max data size must be an integer multiple of 128*256, because each block will have 256 threads,
// and the block grid width will be 128. These are arbitrary numbers I choose.
#define THREADS_PER_BLOCK	256

__global__ void NaiveKernel(int *pA, int *pB, int *pC, int *pD, int *pMaxResult)
{
	// We are assuming 256 threads per block
	// This function is very simple!
	// Too many atomic operations on the same address will cause  massive slowdown

	int index = blockIdx.x * blockDim.x + threadIdx.x;
	int myResult = pA[index] * pB[index] / pC[index] + pD[index];

	atomicMax(pMaxResult, myResult);
	atomicAdd(pMaxResult, 1);
}
__global__ void BetterKernel(int *pA, int *pB, int *pC, int *pD, int *pMaxResult)
{
	// We are assuming 256 threads per block
	// This function is still fairly simple
	// We try to cull out some unnecessary atomic operations.

	__shared__ int curGlobalMax;

	int index = blockIdx.x * blockDim.x + threadIdx.x;
	int myResult = pA[index] * pB[index] / pC[index] + pD[index];

	//if (threadIdx.x == 0)
	//{
	//	// Remember, *pMaxResult will be changing all the time
	//	// We're just taking a snapshot, and putting it into shared memory
	//	curGlobalMax = *pMaxResult;
	//}

	__syncthreads();

	if (myResult > curGlobalMax)
	{
		// Only do an atomic operation if there is a chance we have a greater value
		atomicMax(pMaxResult, myResult);
	}
}

__global__ void SmartKernel(int *pA, int *pB, int *pC, int *pD, int *pMaxResult)
{
	// We are assuming 256 threads per block
	__shared__ int results[256];

	// This function is slightly more complicated, but has the highest performance.

	int index = blockIdx.x * blockDim.x + threadIdx.x;
	int myResult = pA[index] * pB[index] / pC[index] + pD[index];
	results[threadIdx.x] = myResult;
	__syncthreads();

	// Do reduction in shared mem
	for (unsigned int i = blockDim.x / 2; i > 0; i >>= 1)
	{
		if (threadIdx.x < i)
		{
			if (results[threadIdx.x + i] > myResult)
			{
				myResult = results[threadIdx.x + i];
				results[threadIdx.x] = myResult;
			}
		}
		__syncthreads();
	}

	// We now have the maximum value stored in results[0];
	// That happens to be identical to local variable myResult

	if (threadIdx.x == 0)
	{
		atomicMax(pMaxResult, myResult);
	}
}

__global__ void SmarterKernel(int *pA, int *pB, int *pC, int *pD, int *pMaxResult)
{
	// We are assuming 256 threads per block
	__shared__ int results[256];

	// This function is slightly more complicated, but has the highest performance.
	// This function requires CUDA compute capability 1.2 or higher

	int index = blockIdx.x * blockDim.x + threadIdx.x;
	int myResult = pA[index] * pB[index] / pC[index] + pD[index];
	results[threadIdx.x] = myResult;
	__syncthreads();

	// Do reduction in shared mem
	for (unsigned int i = blockDim.x / 2; i > 0; i >>= 1)
	{
		if (threadIdx.x < i)
		{
			atomicMax(&(results[threadIdx.x]), results[threadIdx.x + i]);
		}
		__syncthreads();
	}

	// We now have the maximum value stored in results[0];

	if (threadIdx.x == 0)
	{
		atomicMax(pMaxResult, results[0]);
	}
}

void getMaxCPU(int *h_result, int *h_A, int *h_B, int *h_C, int *h_D, int nElems)
{
	int max = 0;
	for (int i = 0; i < nElems; i++)
	{
		int result = h_A[i] * h_B[i] / h_C[i] + h_D[i];
		if (result > max) max = result;
	}
	*h_result = max;
}

////////////////////////////////////////////////////////////////////////////////
// Main program
////////////////////////////////////////////////////////////////////////////////
int main(int argc, char **argv) {
	int *h_A, *h_B, *h_C, *h_D, *h_result;
	int *d_A, *d_B, *d_C, *d_D, *d_result;
	double gpuTime;
	int i;

	unsigned int hTimer;
	cudaEvent_t start, stop;
	cudaError_t cudaStatus;

	// Allocate CUDA events that we'll use for timing
	checkCudaErrors(cudaEventCreate(&start));
	checkCudaErrors(cudaEventCreate(&stop));

	printf("Initializing data...\n");

	h_A = (int *)malloc(sizeof(int) * MAX_DATA_SIZE);
	h_B = (int *)malloc(sizeof(int) * MAX_DATA_SIZE);
	h_C = (int *)malloc(sizeof(int) * MAX_DATA_SIZE);
	h_D = (int *)malloc(sizeof(int) * MAX_DATA_SIZE);
	h_result = (int*)malloc(sizeof(int));

	(cudaMalloc((void **)&d_A, sizeof(int) * MAX_DATA_SIZE));
	(cudaMalloc((void **)&d_B, sizeof(int) * MAX_DATA_SIZE));
	(cudaMalloc((void **)&d_C, sizeof(int) * MAX_DATA_SIZE));
	(cudaMalloc((void **)&d_D, sizeof(int) * MAX_DATA_SIZE));
	(cudaMalloc((void **)&d_result, sizeof(int)));

	//srand(123);
	for (i = 0; i < MAX_DATA_SIZE; i++)
	{
		h_A[i] = rand();
		h_B[i] = rand();
		h_C[i] = rand() + 1;	// so we don't worry about dividing by zero
		h_D[i] = rand();
	}


	int firstRun = 1;	// Indicates if it's the first execution of the for loop
	const int useGPU = 1;	// When 0, only the CPU is used. When 1, only the GPU is used

	for (int dataAmount = MAX_DATA_SIZE; dataAmount > 128 * THREADS_PER_BLOCK; dataAmount /= 2)
	{

		int blockGridWidth = dataAmount / THREADS_PER_BLOCK;
		int blockGridHeight = 1;

		dim3 blockGridRows(blockGridWidth, blockGridHeight);
		dim3 threadBlockRows(THREADS_PER_BLOCK, 1);

		// Start the timer.
		// We want to measure copying data, running the kernel, and copying the results back to host


		if (useGPU == 1)
		{
			// Record the start event
			checkCudaErrors(cudaEventRecord(start, NULL));
			// Copy the data to the device
			*h_result = 0;

			(cudaMemcpy(d_A, h_A, sizeof(int) * dataAmount, cudaMemcpyHostToDevice));
			(cudaMemcpy(d_B, h_B, sizeof(int) * dataAmount, cudaMemcpyHostToDevice));
			(cudaMemcpy(d_C, h_C, sizeof(int) * dataAmount, cudaMemcpyHostToDevice));
			(cudaMemcpy(d_D, h_D, sizeof(int) * dataAmount, cudaMemcpyHostToDevice));
			(cudaMemcpy(d_result, h_result, sizeof(int) * 1, cudaMemcpyHostToDevice));

			// Do calculations and find max on the GPU
			//NaiveKernel<<<blockGridRows, threadBlockRows>>>(d_A, d_B, d_C, d_D, d_result);
			BetterKernel<<<blockGridRows, threadBlockRows>>>(d_A, d_B, d_C, d_D, d_result);
			//SmartKernel<<<blockGridRows, threadBlockRows>>>(d_A, d_B, d_C, d_D, d_result);
			//SmarterKernel << <blockGridRows, threadBlockRows >> > (d_A, d_B, d_C, d_D, d_result);
			
			// Stop the timer, print the total round trip execution time.
			// Record the stop event
			checkCudaErrors(cudaEventRecord(stop, NULL));
			
			(cudaThreadSynchronize());

			// Copy the data back to the host. It's just 1 int
			(cudaMemcpy(h_result, d_result, sizeof(int) * 1, cudaMemcpyDeviceToHost));
			printf("Result is : %d\n", *h_result);
		}
		else
		{
			// We're using the CPU only
			getMaxCPU(h_result, h_A, h_B, h_C, h_D, dataAmount);
		}


		cudaStatus = cudaGetLastError();
		if (cudaStatus != cudaSuccess) {
			fprintf(stderr, "addKernel launch failed: %s\n", cudaGetErrorString(cudaStatus));
			getchar();
		}
		// Compute and print the performance
		float msecTotal = 0.0f;
		checkCudaErrors(cudaEventElapsedTime(&msecTotal, start, stop));
		if (!firstRun || !useGPU)
		{
			printf("Elements: %d - Calculation time : %f msec - %f Atomics/sec\n", dataAmount, msecTotal, dataAmount / (msecTotal * 0.001));
		}
		else
		{
			firstRun = 0;
			// We discard the results of the first run because of the extra overhead incurred
			// during the first time a kernel is ever executed.
			dataAmount *= 2;	// reset to first run value
		}
	}

	printf("Cleaning up...\n");
	(cudaFree(d_A));
	(cudaFree(d_B));
	(cudaFree(d_C));
	(cudaFree(d_D));
	(cudaFree(d_result));
	//free(h_A);
	//free(h_B);
	//free(h_C);
	//free(h_D);
	//free(h_result);

	/*CUT_EXIT(argc, argv);*/
}
