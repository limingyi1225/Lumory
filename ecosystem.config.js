   module.exports = {
     apps: [
       {
         name: 'lumory-backend',
         script: './server/index.js',
         watch: false,
         env: {
           NODE_ENV: 'production'
         }
       }
     ]
   };
