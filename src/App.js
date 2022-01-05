import logo from './logo.svg';
import './App.scss';
import react from 'react';
import ImageBrowser from './components/ImageBrowser';


function App() {
  return (
    <div className='container'>
      <p>This is a picture of 2021 </p>
      <ImageBrowser image ="http://www.vuodenluontokuva.fi/vlk/userfiles/vlk2021/sarjavoittajat/e.1._liskomies_pekka%20tuuri.jpg" className="container__img" />
    </div>
  );
}

export default App;
