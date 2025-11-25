const axios = require('axios');
const fs = require('fs');
 
const apiKey = 'prRLLzrSaLaIe9GwwLBQ4KqANQp3ee4m'; // TODO: GET PRESIGNED URL FROM FIVEMANAGE VIA NUI CB TO SERVER SIDE (CHECK DMS WITH CHIP)
const url = 'https://fmapi.net/api/v2/audio';
 
export async function uploadAudioToFivemanage(audioBlob: Blob) {
    const formData = new FormData();
    formData.append('file', audioBlob);
    // Optional metadata field (JSON string)
    formData.append("metadata", JSON.stringify({
        name: 'My audio',
        description: 'This is a recording of something cool',
        // or any other field
    }));
    
    const response = await axios.post(url, formData, {
        headers: {
            Authorization: apiKey,
        }
    });
    return response.data.url;
}