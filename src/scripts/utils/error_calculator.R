# Functions to calculate smape, mae and rmse


# Function to calculate series wise smape values
#
# Parameters
# forecasts - a matrix containing forecasts for a set of series
#             no: of rows should be equal to number of series and no: of columns should be equal to the forecast horizon 
# test_set - a matrix with the same dimensions as 'forecasts' containing the actual values corresponding with them
calculate_smape <- function(forecasts, test_set){
  epsilon <- 0.1
  sum <- NULL
  comparator <- matrix((0.5 + epsilon), nrow = nrow(test_set), ncol = ncol(test_set))
  sum <- pmax(comparator, (abs(forecasts) + abs(test_set) + epsilon))
  smape <- 2 * abs(forecasts - test_set) / (sum)
  msmape_per_series <- rowMeans(smape, na.rm = TRUE)
  msmape_per_series
}


# Function to calculate series wise mae values
#
# Parameters
# forecasts - a matrix containing forecasts for a set of series
#             no: of rows should be equal to number of series and no: of columns should be equal to the forecast horizon 
# test_set - a matrix with the same dimensions as 'forecasts' containing the actual values corresponding with them
calculate_mae <- function(forecasts, test_set){
  mae <- abs(forecasts-test_set)
  mae_per_series <- rowMeans(mae, na.rm=TRUE)
  mae_per_series
}


# Function to calculate series wise rmse values
#
# Parameters
# forecasts - a matrix containing forecasts for a set of series
#             no: of rows should be equal to number of series and no: of columns should be equal to the forecast horizon 
# test_set - a matrix with the same dimensions as 'forecasts' containing the actual values corresponding with them
calculate_rmse <- function(forecasts, test_set){
  squared_errors <- (forecasts-test_set)^2
  rmse_per_series <- sqrt(rowMeans(squared_errors, na.rm=TRUE))
  rmse_per_series
}


# Function to provide a summary of 3 error metrics: smape, mae and rmse
#
# Parameters
# forecasts - a matrix containing forecasts for a set of series
#             no: of rows should be equal to number of series and no: of columns should be equal to the forecast horizon 
# test_set - a matrix with the same dimensions as 'forecasts' containing the actual values corresponding with them
# output_file_name - The prefix of error file names
calculate_errors <- function(forecasts, test_set, output_file_name){
  #calculating smape
  smape_per_series <- calculate_smape(forecasts, test_set)
  
  #calculating mae
  mae_per_series <- calculate_mae(forecasts, test_set)
  
  #calculating rmse
  rmse_per_series <- calculate_rmse(forecasts, test_set)
  
  mean_smape <- paste0("Mean SMAPE: ", mean(smape_per_series))
  mean_mae <- paste0("Mean MAE: ", mean(mae_per_series))
  mean_rmse <- paste0("Mean RMSE: ", mean(rmse_per_series))

  print(mean_smape)
  print(mean_mae)
  print(mean_rmse)

  #writing error measures into files
  write.table(smape_per_series, paste0(output_file_name, "_smape.txt"), row.names = FALSE, col.names = FALSE, sep = ",", quote = FALSE)
  write.table(mae_per_series, paste0(output_file_name, "_mae.txt"), row.names = FALSE, col.names = FALSE, sep = ",", quote = FALSE)
  write.table(rmse_per_series, paste0(output_file_name, "_rmse.txt"), row.names = FALSE, col.names = FALSE, sep = ",", quote = FALSE)
  write(c(mean_smape, mean_mae, mean_rmse, "\n"), file = paste0(output_file_name, ".txt"), append = FALSE)
}
