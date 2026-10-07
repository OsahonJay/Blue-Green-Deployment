pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '10'))
    }

    parameters {
        booleanParam(name: 'FLIP_TRAFFIC', defaultValue: true,
                     description: 'Switch live traffic to the new version once the idle color passes verification')
        booleanParam(name: 'SIMULATE_FAILURE', defaultValue: false,
                     description: 'Fail the post-switch check on purpose to prove the automatic rollback')
    }

    environment {
        IMAGE_REPO         = 'osahonseth1/bankapp'
        IMAGE_TAG          = "build-${env.BUILD_NUMBER}"
        AWS_DEFAULT_REGION = 'eu-west-2'
        PROJECT            = 'bluegreen-bankapp'
    }

    stages {
        stage('Build and test') {
            steps {
                sh './mvnw -B clean package'
            }
            post {
                always {
                    junit allowEmptyResults: true, testResults: 'target/surefire-reports/*.xml'
                }
            }
        }

        stage('Build and push image') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'dockerhub',
                                                  usernameVariable: 'DH_USER',
                                                  passwordVariable: 'DH_PASS')]) {
                    sh '''
                        set -e
                        docker build -t "$IMAGE_REPO:$IMAGE_TAG" .
                        echo "$DH_PASS" | docker login -u "$DH_USER" --password-stdin
                        docker push "$IMAGE_REPO:$IMAGE_TAG"
                        docker logout
                    '''
                }
            }
        }

        stage('Find live and idle color') {
            steps {
                script {
                    env.LIVE = sh(script: './scripts/bluegreen.sh live', returnStdout: true).trim()
                    env.IDLE = (env.LIVE == 'blue') ? 'green' : 'blue'
                    echo "Live color: ${env.LIVE}. Deploying ${env.IMAGE_TAG} to the idle color: ${env.IDLE}"
                }
            }
        }

        stage('Deploy to idle color') {
            steps {
                withCredentials([
                    sshUserPrivateKey(credentialsId: 'app-ssh-key', keyFileVariable: 'SSH_KEY'),
                    string(credentialsId: 'db-password', variable: 'DB_PASSWORD')
                ]) {
                    sh '''
                        set -e
                        ./scripts/bluegreen.sh inventory "$IDLE" ansible/inventory/hosts.ini
                        cd ansible
                        ansible-playbook deploy.yml --limit "$IDLE" --private-key "$SSH_KEY" \
                            -e image_repo="$IMAGE_REPO" -e image_tag="$IMAGE_TAG" \
                            -e health_check_retries=30
                    '''
                }
            }
        }

        stage('Verify idle color directly') {
            steps {
                withCredentials([sshUserPrivateKey(credentialsId: 'app-ssh-key', keyFileVariable: 'SSH_KEY')]) {
                    sh './scripts/bluegreen.sh verify "$IDLE" "$IMAGE_TAG" "$SSH_KEY"'
                }
            }
        }

        stage('Pre-warm idle color') {
            steps {
                sh './scripts/bluegreen.sh prewarm "$LIVE" "$IDLE"'
            }
        }

        stage('Switch traffic') {
            when { expression { return params.FLIP_TRAFFIC } }
            steps {
                script { env.FLIPPED = 'true' }
                sh '''
                    set -e
                    ./scripts/bluegreen.sh flip "$IDLE"
                    ./scripts/bluegreen.sh wait-live "$IDLE" "$IMAGE_TAG"
                '''
            }
        }

        stage('Post-switch check') {
            when { expression { return params.FLIP_TRAFFIC } }
            steps {
                script {
                    if (params.SIMULATE_FAILURE) {
                        error('Simulated failure: the post-switch check was made to fail on purpose')
                    }
                }
                sh './scripts/bluegreen.sh soak "$IDLE" "$IMAGE_TAG" 15'
            }
        }
    }

    post {
        success {
            script {
                if (params.FLIP_TRAFFIC) {
                    echo "Done: ${env.IMAGE_TAG} is live on ${env.IDLE}. ${env.LIVE} is idle and holds the previous version for rollback."
                } else {
                    echo "Done: ${env.IMAGE_TAG} is deployed and verified on ${env.IDLE}, but traffic was not switched."
                }
            }
        }
        failure {
            script {
                if (env.FLIPPED == 'true') {
                    echo "Failure after the switch: rolling traffic back to ${env.LIVE}"
                    sh './scripts/bluegreen.sh rollback "$LIVE"'
                } else {
                    echo 'Failure before the switch: live traffic was never touched.'
                }
            }
        }
        always {
            sh 'docker image prune -af --filter "until=24h" || true'
        }
    }
}
