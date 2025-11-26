export function requestYoutubeAudio(videoId: string) {
    const data = null;

    const xhr = new XMLHttpRequest();
    xhr.withCredentials = true;

    xhr.addEventListener('readystatechange', function () {
        if (this.readyState === this.DONE) {
            console.log(this.responseText);
        }
    });

    xhr.open('GET', 'https://youtube-mp36.p.rapidapi.com/dl?id=' + videoId);
    xhr.setRequestHeader('x-rapidapi-key', '653143bc39mshb7de6b5c6a7fe0bp15d62cjsne8faac1aa59a');
    xhr.setRequestHeader('x-rapidapi-host', 'youtube-mp36.p.rapidapi.com');
    return new Promise((resolve, reject) => {
        xhr.onload = () => {
            resolve(JSON.parse(xhr.responseText).link as string);
        };
        xhr.onerror = () => {
            reject(new Error('Failed to request YouTube audio'));
        };
        xhr.send(data);
    });
}