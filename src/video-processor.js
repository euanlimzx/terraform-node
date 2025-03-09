// File: video-processor.js
const AWS = require("aws-sdk");
const fs = require("fs");
const path = require("path");

// Initialize S3 client
const s3 = new AWS.S3();

async function processVideo() {
  const sourceBucket = process.env.SOURCE_BUCKET;
  const destinationBucket = process.env.DESTINATION_BUCKET;
  console.log("Reading from: ", sourceBucket);
  console.log("Uploading to: ", destinationBucket);

  try {
    // List objects in the source bucket
    const listObjectsResponse = await s3
      .listObjectsV2({
        Bucket: sourceBucket,
      })
      .promise();

    if (listObjectsResponse.Contents.length === 0) {
      console.log("No objects found in source bucket.");
      return;
    }

    // Get the first object from the list
    const firstObject = listObjectsResponse.Contents[0];
    console.log("First object found: ", firstObject.Key);

    // Download the first object
    const downloadParams = {
      Bucket: sourceBucket,
      Key: firstObject.Key,
    };

    const fileStream = fs.createWriteStream(
      path.join(__dirname, firstObject.Key)
    );
    const objectData = await s3.getObject(downloadParams).promise();
    fileStream.write(objectData.Body);
    fileStream.end();

    console.log(`Downloaded ${firstObject.Key} to local file system.`);

    // Upload the file to the destination bucket
    const uploadParams = {
      Bucket: destinationBucket,
      Key: firstObject.Key,
      Body: fs.createReadStream(path.join(__dirname, firstObject.Key)),
    };

    const uploadResponse = await s3.upload(uploadParams).promise();
    console.log(
      `Successfully uploaded ${firstObject.Key} to destination bucket.`
    );
    console.log(uploadResponse);
    // Optionally, delete the local file after upload
    fs.unlinkSync(path.join(__dirname, firstObject.Key));
  } catch (error) {
    console.error("Error processing video: ", error);
  }
}

processVideo();
