# Blue Djinn

<img src="assets/app_icons/blue-djinn.png" width="720">

A Dart(Flutter) tool for software development focused on using local LLMs via [Ollama](https://ollama.com) API. This started as a fork of [dauillamma](https://github.com/rxlabz/dauillama).

- uses [Ollama Dart](https://pub.dev/packages/ollama_dart)

## Usage

Launch Ollama desktop app or run [ollama serve](https://github.com/ollama/ollama#start-ollama).

The [OllamaClient](https://pub.dev/documentation/ollama_dart/latest/ollama_dart/OllamaClient-class.html) attempts to retrieve the `OLLAMA_BASE_URL` from the environment variables, defaulting to http://127.0.0.1:11434/api if it is not set.

## Platforms
- [x] Macos
- [ ] Windows
- [x] Linux
- [ ] Web

## Features

- [x] generate a chat completion
- [x] list models
- [x] show model information
- [x] pull a model
- [x] update a model  
- [x] delete a model
- [x] Chat history
- [ ] temperature & model options 
- [ ] create a model (modelFile)
- [ ] prompt templates library
- [ ] ollama settings customization

## Screenshots

<img src="assets/screenshots/conversation.png" width="720">

___

<img src="assets/screenshots/models.png" width="720">

___

<img src="assets/screenshots/model_info.png" width="720">

___

<img src="assets/screenshots/multi_modal.png" width="720">

___

<img src="assets/screenshots/pull_model.png" width="720">

---

<img src="assets/screenshots/light.png" width="720">
