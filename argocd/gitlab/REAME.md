Only if we use the insecure method with the following code:
```
- name: gitlab-runner.gitlabUrl
    value: 'http://gitlab-webservice-default:8181/'
```
In this case add the variable `GIT_SSL_NO_VERIFY="true"̀  in the admin Area => CI/CD => Variables
