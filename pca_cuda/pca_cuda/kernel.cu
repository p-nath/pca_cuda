#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <assert.h>
#include <stdbool.h>
#include <time.h>

#define TILE_DIM 16


//matrix.h
typedef struct {
	int rows;
	int columns;
	double **data;
} Matrix;

Matrix* CreateNewMatrix(int n, int m);

Matrix* ReadMatrix(char *file_name);

void WriteMatrix(FILE* file_pointer, Matrix* matrix);

Matrix* Transpose(Matrix* matrix);

Matrix* Covariance(Matrix* matrix);

Matrix* Product(Matrix* m1, Matrix* m2);

Matrix* Mean(Matrix* matrix);

void DestroyMatrix(Matrix* matrix);

double GetNorm(Matrix* matrix);

Matrix* GetColumnMatrix(Matrix* matrix, int column_no);

Matrix* MakeColumnMatrix(Matrix* column_matrix, int column_no);

Matrix* GetRowMatrix(Matrix* matrix, int row_no);

Matrix* MakeRowMatrix(Matrix* row_matrix, int row_no);

Matrix* Difference(Matrix* A, Matrix* B);

Matrix* ScalarDivide(Matrix* matrix, double x);

Matrix* GetIdentityMatrix(int x); // x = rows = columns

void CopyMatrix(Matrix* A, Matrix* B); // B is the matrix which is copied to A

void Bidiagonalize(Matrix* A, Matrix* U, Matrix* V_t);

//svd.h
void QR_Decomposition(Matrix* B, Matrix* Q, Matrix* R);

void QR_Converge(Matrix* B, Matrix* Q, Matrix* Q_t, Matrix* R, int max_iterations);

void SVD(Matrix* A, Matrix* U, Matrix* Z, Matrix* V, int max_iterations);

Matrix* CreateProjectionMatrix(Matrix* U, int initial_dimensions, int final_dimensions);

//pca_main.c
void help(char** argv) {
	printf("%s -i <input_filename> -o <output_filename> -m <max_iterations>\n", argv[0]);
}

bool parse_args(int argc, char** argv, char **input_filename,
	char **output_filename, int* max_iterations) {
	if (argc < 3)
		return false;
	for (int i = 0; i < argc; i++) {
		if (strcmp(argv[i], "-i") == 0 && i + 1 < argc) {
			i++;
			*input_filename = argv[i];
		}
		if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) {
			i++;
			*output_filename = argv[i];
		}
		if (strcmp(argv[i], "-m") == 0 && i + 1 < argc) {
			i++;
			*max_iterations = atoi(argv[i]);
		}
	}
	return true;
}

//main function
int main(int argc, char **argv) {
	clock_t start = clock(), end;
	double computational_time;

	int max_iterations = 0;
	FILE *fout = NULL;
	if (!(fout = fopen("output.txt", "w")))  fout = stdout;
	if (max_iterations <= 0)  max_iterations = 30;

	Matrix *A = NULL;
	A = ReadMatrix("iris_data.txt");
	//WriteMatrix(stdout, A);

	Matrix *U = GetIdentityMatrix(A->columns);
	Matrix *V = GetIdentityMatrix(A->columns);
	Matrix *Z = CreateNewMatrix(A->columns, A->columns);
	SVD(A, U, Z, V, max_iterations);

	printf("after SVD(U, S, V) \n");
	printf("U = \n");
	WriteMatrix(stdout, U);
	printf("\n");
	printf("S = \n");
	WriteMatrix(stdout, Z);
	printf("\n");
	printf("V = \n");
	WriteMatrix(stdout, V);
	printf("\n");

	int initial_dimensions = 4;
	int final_dimensions = 3;
	Matrix* W = CreateProjectionMatrix(U, initial_dimensions, final_dimensions);

	Matrix *Y = Product(A, W);
	WriteMatrix(fout, Y);

	if (!(fout == stdout)) {
		printf("Output was written.\n" );
		fclose(fout);
	}
	end = clock();
	computational_time = ((double)(end - start))/CLOCKS_PER_SEC;
	printf("Computational Time = %lf seconds\n", computational_time);
	return 0;
}

//matrix.c -- contains cudaproduct()


Matrix* CreateNewMatrix(int n, int m) {
	Matrix* matrix = (Matrix*)malloc(sizeof(Matrix));
	matrix->rows = n;
	matrix->columns = m;
	matrix->data = (double**)malloc(sizeof(double)*n);
	for (int i = 0; i < n; i++){
		matrix->data[i] = (double*)malloc(sizeof(double)*m);
	}
	return matrix;
}


void DestroyMatrix(Matrix* matrix) {
	for (int n = 0; n < matrix->rows; n++) {
		free(matrix->data[n]);
	}
	free(matrix);
}

Matrix* ReadMatrix(char *file_name) {
	double x;
	int r, c;
	FILE *fin;
	fin = fopen(file_name, "r");
	fscanf(fin, "%d", &r);
	fseek(fin, 1, SEEK_CUR);
	fscanf(fin, "%d", &c);
	fseek(fin, 1, SEEK_CUR);
	Matrix* matrix = CreateNewMatrix(r, c);
	for (int n = 0; n < matrix->rows; n++) {
		for (int m = 0; m < matrix->columns; m++) {
			fscanf(fin, "%lf", &x);
			fseek(fin, 1, SEEK_CUR);
			matrix->data[n][m] = x;
		}
	}
	fclose(fin);
	printf("Matrix read from %s\n", file_name);
	return matrix;
}

void WriteMatrix(FILE* file_pointer, Matrix* matrix) {
	for (int n = 0; n < matrix->rows; n++) {
		for (int m = 0; m < matrix->columns; m++) {
			if (m == matrix->columns - 1)  fprintf(file_pointer, "%lf\n", matrix->data[n][m]);
			else  fprintf(file_pointer, "%lf ", matrix->data[n][m]);
		}
	}
}

Matrix* Transpose(Matrix* matrix) {
	Matrix* transpose;
	transpose = CreateNewMatrix(matrix->columns, matrix->rows);
	for (int n = 0; n < transpose->rows; n++) {
		for (int m = 0; m < transpose->columns; m++) {
			transpose->data[n][m] = matrix->data[m][n];
		}
	}
	return transpose;
}
__global__ void MatMulNoShared(double* A, double* B, double* C, int ARows, int ACols, int BRows, int BCols, int CRows, int CCols) {

	double CValue = 0;

	int Row = blockIdx.y*TILE_DIM + threadIdx.y;
	int Col = blockIdx.x*TILE_DIM + threadIdx.x;
	if (Row < CRows && Col < CCols) {
		for (int i = 0; i < ACols; i++) {
			CValue += A[Row*ACols + i] * B[i*BCols + Col];
		}
		C[Row*BCols + Col] = CValue;
	}
}

Matrix* Product(Matrix* m1, Matrix* m2) {
	int ARows = m1->rows, ACols = m1->columns;
	int BRows = m2->rows, BCols = m2->columns;
	int CRows = m1->rows, CCols = m2->columns;

	double* hostC = (double*)malloc(CRows*CCols*sizeof(double));
	double* hostA = (double*)malloc(sizeof(double)*ACols*ARows);
	double* hostB = (double*)malloc(sizeof(double)*BCols*BRows);

	for (int i = 0; i < ARows; i++) {
		for (int j = 0; j < ACols; j++) {
			hostA[i*ACols + j] = m1->data[i][j];
		}
	}
	//Write1D(stdout, hostA, ARows, ACols);
	for (int i = 0; i < BRows; i++) {
		for (int j = 0; j < BCols; j++) {
			hostB[i*BCols + j] = m2->data[i][j];
		}
	}
	//Write1D(stdout, hostB, BRows, BCols);

	dim3 dimBlock(TILE_DIM, TILE_DIM, 1);
	dim3 dimGrid;

	dimGrid.x = (CCols + dimBlock.x - 1) / dimBlock.x;
	dimGrid.y = (CRows + dimBlock.y - 1) / dimBlock.y;

	double *deviceA, *deviceB, *deviceC;

	cudaMalloc((void **)&deviceA, ARows*ACols*sizeof(double));
	cudaMalloc((void **)&deviceB, BRows*BCols*sizeof(double));
	cudaMalloc((void **)&deviceC, CCols*CRows*sizeof(double));

	cudaMemcpy(deviceA, hostA, ARows*ACols*sizeof(double), cudaMemcpyHostToDevice);
	cudaMemcpy(deviceB, hostB, BRows*BCols*sizeof(double), cudaMemcpyHostToDevice);

	MatMulNoShared << <dimGrid, dimBlock >> >(deviceA, deviceB, deviceC, ARows, ACols, BRows, BCols, CRows, CCols);
	cudaMemcpy(hostC, deviceC, CRows*CCols*sizeof(double), cudaMemcpyDeviceToHost);
	
	Matrix* m3 = CreateNewMatrix(CRows, CCols);
	for (int i = 0; i < CRows; i++)
		for (int j = 0; j < CCols; j++)
			m3->data[i][j] = hostC[i * CCols + j];
	
	return m3;
}

Matrix* Mean(Matrix* matrix) {
	double* column_avg = (double*)malloc(sizeof(double)*matrix->columns);
	double sum = 0;
	Matrix* mean = CreateNewMatrix(matrix->rows, matrix->columns);
	for (int n = 0; n < matrix->columns; n++) {
		sum = 0;
		for (int m = 0; m < matrix->rows; m++) {
			sum += matrix->data[m][n];
		}
		column_avg[n] = sum / mean->rows;
	}
	for (int m = 0; m < mean->columns; m++) {
		for (int n = 0; n < mean->rows; n++) {
			mean->data[n][m] = matrix->data[n][m] - column_avg[m];
		}
	}
	return mean;
}

Matrix* Covariance(Matrix* matrix) {
	Matrix* covariance = CreateNewMatrix(matrix->columns, matrix->columns);
	Matrix* mean = Mean(matrix);
	Matrix* transpose = Transpose(mean);
	Matrix* product = Product(transpose, mean);

	for (int n = 0; n < covariance->rows; n++) {
		for (int m = 0; m < covariance->columns; m++) {
			covariance->data[n][m] = product->data[n][m] / (matrix->rows - 1);
		}
	}
	DestroyMatrix(mean);
	DestroyMatrix(transpose);
	DestroyMatrix(product);
	return covariance;
}


double GetNorm(Matrix* matrix) {
	double norm, sum_of_squares = 0;
	for (int n = 0; n < matrix->rows; n++)
		for (int m = 0; m < matrix->columns; m++) {
			sum_of_squares += pow(matrix->data[n][m], 2);
		}
	norm = sqrt(sum_of_squares);
	return norm;
}

Matrix* GetColumnMatrix(Matrix* matrix, int column_no) {
	Matrix* column_matrix = CreateNewMatrix(matrix->rows, 1);
	for (int n = 0; n < column_matrix->rows; n++) {
		column_matrix->data[n][0] = matrix->data[n][column_no];
	}
	return column_matrix;
}

Matrix* MakeColumnMatrix(Matrix* column_matrix, int column_no) {
	Matrix* new_matrix = CreateNewMatrix(column_matrix->rows, 1);
	if (column_no == 0){
		for (int n = 0; n < new_matrix->rows; n++) {
			if (n == column_no)
				new_matrix->data[n][0] = GetNorm(column_matrix);
			else new_matrix->data[n][0] = 0;
		}
	}
	else {
		for (int n = 0; n < new_matrix->rows; n++) {
			if (n < column_no)
				new_matrix->data[n][0] = column_matrix->data[n][0];
			else if (n == column_no) {
				double norm = GetNorm(column_matrix);
				double value = sqrt(pow(norm, 2) - pow(column_matrix->data[n - 1][0], 2));
				new_matrix->data[n][0] = value;
			}
			else new_matrix->data[n][0] = 0;
		}
	}
	return new_matrix;
}


Matrix* GetRowMatrix(Matrix* matrix, int row_no) {
	Matrix* row_matrix = CreateNewMatrix(1, matrix->columns);
	for (int m = 0; m < row_matrix->columns; m++) {
		row_matrix->data[0][m] = matrix->data[row_no][m];
	}
	return row_matrix;
}

Matrix* MakeRowMatrix(Matrix* row_matrix, int row_no) {
	Matrix* new_matrix = CreateNewMatrix(1, row_matrix->columns);
	for (int m = 0; m < new_matrix->columns; m++) {
		if (m <= row_no)
			new_matrix->data[0][m] = row_matrix->data[0][m];
		else if (m == row_no + 1) {
			double norm = GetNorm(row_matrix);
			double value = sqrt(pow(norm, 2) - pow(row_matrix->data[0][m - 1], 2));
			new_matrix->data[0][m] = value;
		}
		else new_matrix->data[0][m] = 0;

	}
	return new_matrix;
}

Matrix* Difference(Matrix* A, Matrix* B) {
	if (A->rows != B->rows || A->columns != B->columns)  return NULL;
	Matrix* diff = CreateNewMatrix(A->rows, A->columns);
	for (int n = 0; n < diff->rows; n++) {
		for (int m = 0; m < diff->columns; m++) {
			diff->data[n][m] = A->data[n][m] - B->data[n][m];
		}
	}
	return diff;
}

Matrix* ScalarDivide(Matrix* matrix, double x) {
	Matrix* div = CreateNewMatrix(matrix->rows, matrix->columns);
	for (int n = 0; n < div->rows; n++) {
		for (int m = 0; m < div->columns; m++) {
			div->data[n][m] = matrix->data[n][m] / x;
		}
	}
	return div;
}

Matrix* GetIdentityMatrix(int x) {
	Matrix* I = CreateNewMatrix(x, x);
	for (int n = 0; n < I->rows; n++) {
		for (int m = 0; m < I->columns; m++) {
			if (n == m)  I->data[n][m] = 1;
			else  I->data[n][m] = 0;
		}
	}
	return I;
}

void CopyMatrix(Matrix* A, Matrix* B) {
	for (int n = 0; n < A->rows; n++) {
		for (int m = 0; m < A->columns; m++) {
			A->data[n][m] = B->data[n][m];
		}
	}
}

void Bidiagonalize(Matrix* A, Matrix* U, Matrix* V) {
	int m = 0, n = 0, m_limit, n_limit;
	if (A->rows > A->columns) {
		m_limit = A->columns;
		n_limit = A->columns - 2;
	}
	else if (A->rows == A->columns) {
		m_limit = A->columns - 1;
		n_limit = A->rows - 2;
	}
	else {
		m_limit = A->rows - 1;
		n_limit = A->rows;
	}

	Matrix *x, *y, *z, *w, *w_t, *I, *product, *product2, *U_curr, *U_final, *V_final, *V_curr, *A_final;
	while (1){
		if (m == m_limit && n == n_limit)  break;
		if (m < m_limit) {
			//printf("row mainp %d\n",m);
			I = GetIdentityMatrix(A->rows);
			x = GetColumnMatrix(A, m);
			y = MakeColumnMatrix(x, m);
			z = Difference(x, y);
			w = ScalarDivide(z, GetNorm(z));
			w_t = Transpose(w);
			product = Product(w, w_t);
			product2 = ScalarDivide(product, 0.5);
			U_curr = Difference(I, product2);
			A_final = Product(U_curr, A);
			CopyMatrix(A, A_final);
			if (m == 0)
				CopyMatrix(U, U_curr);
			else {
				U_final = Product(U_curr, U);
				CopyMatrix(U, U_final);
				DestroyMatrix(U_final);
			}
			DestroyMatrix(I);
			DestroyMatrix(x);
			DestroyMatrix(y);
			DestroyMatrix(z);
			DestroyMatrix(w);
			DestroyMatrix(product);
			DestroyMatrix(product2);
			DestroyMatrix(A_final);
			m++;
		}
		if (n < n_limit) {
			I = GetIdentityMatrix(A->columns);
			x = GetRowMatrix(A, n);
			y = MakeRowMatrix(x, n);
			z = Difference(x, y);
			w = ScalarDivide(z, GetNorm(z));
			w_t = Transpose(w);
			product = Product(w_t, w);
			product2 = ScalarDivide(product, 0.5);
			V_curr = Difference(I, product2);
			A_final = Product(A, V_curr);

			CopyMatrix(A, A_final);
			if (n == 0)
				CopyMatrix(V, V_curr);
			else {
				V_final = Product(V, V_curr);
				CopyMatrix(V, V_final);
				DestroyMatrix(V_final);
			}
			DestroyMatrix(I);
			DestroyMatrix(x);
			DestroyMatrix(y);
			DestroyMatrix(z);
			DestroyMatrix(w);
			DestroyMatrix(product);
			DestroyMatrix(product2);
			DestroyMatrix(A_final);
			n++;
		}
	}
}

//svd.c
Matrix* assert_square_matrix(Matrix* A) {
	assert(A->rows == A->columns);
	return A;
}

//for square symmetric matrices / covariance matrices
void QR_Decomposition(Matrix* B, Matrix* Q, Matrix* R) {
	assert_square_matrix(B);
	double t, r, c, s;
	Matrix* P = NULL;
	Matrix* Q_temp = NULL;
	Matrix* G_t = NULL;
	Matrix* G = CreateNewMatrix(B->rows, B->columns);
	//Givens rotation
	CopyMatrix(R, B);
	for (int count = 0; count < B->rows - 1; count++) {
		t = R->data[count + 1][count];
		r = sqrt(pow(R->data[count][count], 2) + pow(t, 2));
		c = R->data[count][count] / r;
		s = t / r;
		for (int i = 0; i < G->rows; i++) {
			for (int j = 0; j < G->columns; j++) {
				if ((i == count && j == count) || (i == count + 1 && j == count + 1))  G->data[i][j] = c;
				else if (i == count + 1 && j == count)  G->data[i][j] = -1 * s;
				else if (i == count && j == count + 1)  G->data[i][j] = s;
				else if (i == j)  G->data[i][j] = 1;
				else  G->data[i][j] = 0;
			}
		}
		P = Product(G, R);
		CopyMatrix(R, P);
		G_t = Transpose(G);
		if (count == 0) CopyMatrix(Q, G_t);
		else {
			Q_temp = Product(Q, G_t);
			CopyMatrix(Q, Q_temp);
			DestroyMatrix(Q_temp);
		}
		DestroyMatrix(G_t);
		DestroyMatrix(P);
	}
	DestroyMatrix(G);
}

void QR_Converge(Matrix* B, Matrix* Q, Matrix* Q_t, Matrix* R, int max_iterations) {
	QR_Decomposition(B, Q, R);
	Matrix* A2 = Product(R, Q);
	Matrix* Q_temp = CreateNewMatrix(Q->rows, Q->columns);
	Matrix* Q_t_temp = CreateNewMatrix(Q->columns, Q->rows);
	Matrix* Q_product = NULL, *Q_t_product = NULL;
	Matrix* _Q_t = Transpose(Q);

	CopyMatrix(Q_t, _Q_t);
	DestroyMatrix(_Q_t);
	CopyMatrix(Q_temp, Q);
	CopyMatrix(Q_t_temp, Q_t);
	// here use cuda c -- check dependencies
	for (int i = 0; i < max_iterations; i++) {
		QR_Decomposition(A2, Q, R);
		A2 = Product(R, Q);
		Q_product = Product(Q_temp, Q);
		_Q_t = Transpose(Q);
		CopyMatrix(Q_t, _Q_t);
		Q_t_product = Product(Q_t, Q_t_temp);
		CopyMatrix(Q_temp, Q_product);
		CopyMatrix(Q_t_temp, Q_t_product);
		DestroyMatrix(_Q_t);
	}
	CopyMatrix(Q, Q_product);
	CopyMatrix(Q_t, Q_t_product);
	DestroyMatrix(Q_product);
	DestroyMatrix(Q_t_product);


	DestroyMatrix(A2);
	DestroyMatrix(Q_temp);
	DestroyMatrix(Q_t_temp);

}

void SVD(Matrix* A, Matrix* U, Matrix* Z, Matrix* V, int max_iterations) {
	Matrix* covariance = Covariance(A);
	printf("The covariance matrix:\n");
	WriteMatrix(stdout, covariance);
	printf("\n");
	QR_Converge(covariance, U, V, Z, max_iterations);
	DestroyMatrix(covariance);
}

Matrix* CreateProjectionMatrix(Matrix* U, int initial_dimensions, int final_dimensions) {
	Matrix* W = CreateNewMatrix(initial_dimensions, final_dimensions);
	CopyMatrix(W, U);
	return W;
}
